require 'tempfile'
require 'json'
require 'socket'
require 'uri'
require 'net/http'
require 'docker'
require 'memfs'
require 'pp'

##################################################################
# TODO
# This is way too magical. Need a better way for plugin interface.
##################################################################
old_constants = Object.constants

$:.unshift './'
Dir.glob(File.dirname(File.expand_path(__FILE__)) + '/plugins/*rb').each do |plugin|
  require plugin
end

PLUGINS = Object.constants - old_constants
##################################################################

# Error Classes
class RundeckDockerPluginError < StandardError; end

class RundeckDockerMesosPluginNoLeader < RundeckDockerPluginError
  def initialize hosts
    @hosts = hosts
  end

  def message
    "Cannot find leader in hostnames: #{@hosts}"
  end
end

class RundeckDockerPluginMissingPluginType < RundeckDockerPluginError
  def message
    'Nothing to do. Please select one node with dockerPluginType defined.'
  end
end

class RundeckDockerPluginInvalidPluginType < RundeckDockerPluginError
  def initialize types
    @types = types
  end

  def message
    "Please select one node with a valid dockerPluginType. " \
    "Allowable types: #{@types}"
  end
end

class RundeckDockerPluginMissingDockerImage < RundeckDockerPluginError
  def message
    'Must have docker image specified.'
  end
end

class RundeckDockerMesosPluginInvalidMesosCredConfig < RundeckDockerPluginError
  def message
    'Must have mesos secret AND principal defined.'
  end
end

class RundeckDockerPluginMissingProtocol < RundeckDockerPluginError
  def message
    'Please define a protocol to use E.g. tcp, unix'
  end
end


# Main interface to execute containers against a given host with a valid
# ALLOWABLE_TYPES
class RundeckDockerPlugin

  ALLOWABLE_TYPES = %w[mesos docker]

  def self.run
    plugin_type = ENV['RD_NODE_DOCKERPLUGINTYPE']

    if 'mesos' == plugin_type
      RundeckDockerMesos.new.run
    elsif 'docker' == plugin_type
      RundeckDocker.new.run
    elsif '' == plugin_type || plugin_type.nil?
      raise RundeckDockerPluginMissingPluginType
    elsif !ALLOWABLE_TYPES.include?(plugin_type)
      raise RundeckDockerPluginInvalidPluginType, ALLOWABLE_TYPES
    end
  end

  def initialize
    @node_port = ENV['RD_NODE_PORT'] ? ":#{ENV['RD_NODE_PORT']}" : nil
    @image = ENV['RD_CONFIG_DOCKER_IMAGE'] or
      raise RundeckDockerPluginMissingDockerImage
    @command = ENV['RD_CONFIG_DOCKER_COMMAND']
    @envvars = (envvars = ENV['RD_CONFIG_DOCKER_ENV_VARS'] and
                envvars.split("\n"))
    @hostnames = hostnames
    @config = config
  end

  def config
    config = JSON.parse(ENV['RD_CONFIG_DOCKER_CONFIG_JSON'] || "{}")
    return config if config.empty?

    case config['version']
    when '1.0.0'
      node_data = (nodes = config['nodes'] and nodes[ENV['RD_NODE_NAME']]) || {}
      global_data = config['global'] || {}

      global_data.merge(node_data, &deep_merge_proc)
    else
      STDERR.puts "Unsupported config version: #{config['version']}"
    end
  end

  def force_pull?
    ENV['RD_CONFIG_DOCKER_PULL_IMAGE'] == 'true'
  end

  def debug?
    ENV['RD_JOB_LOGLEVEL'] == 'DEBUG'
  end

  def hostnames
    hosts = if hsts = ENV['RD_NODE_HOSTNAMES']
              hsts.gsub(/[\[\]\s]/, '').split ','
            else
              []
            end
    hosts << ENV['RD_NODE_HOSTNAME']
    hosts.compact.reject(&:empty?)
  end

  def deep_merge_proc
    merger = proc { |key, v1, v2|
      Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2
    }
    merger
  end

end


# Responsible for interface to docker
class RundeckDocker < RundeckDockerPlugin
  def initialize
    super
    @protocol = ENV['RD_NODE_PROTOCOL'] or
      raise RundeckDockerPluginMissingProtocol
    @ca_pem = ENV['RD_CONFIG_DOCKER_CA_PEM_FILE'] ||
      @config['docker']['ca.pem'] rescue nil
    @cert_pem = ENV['RD_CONFIG_DOCKER_CERT_PEM_FILE'] ||
      @config['docker']['cert.pem'] rescue nil
    @key_pem = ENV['RD_CONFIG_DOCKER_KEY_PEM_FILE'] ||
      @config['docker']['key.pem'] rescue nil
  end

  # TODO clean up. Too long and complex. Use extract method refactor.
  def run
    before_run
    exit_code = 0

    MemFs.activate!

    setup_connection
    pull_image

    create_hash = {
      'Image' => @image,
    }
    @envvars and create_hash['Env'] = @envvars
    @command and create_hash['Cmd'] = @command.split
    secret_plugin = nil
    secret_klass = Object.constants.find do |const|
      const === :RundeckDockerSecretsPlugin
    end

    if secret_klass
      secret_plugin = Object.const_get(secret_klass).new @config
      if secret_plugin.respond_to? :secrets_config
        create_hash.merge! secret_plugin.secrets_config
      end
    end

    container = Docker::Container.create create_hash

    container.start
    json = container.json

    info = "Container '#{@image}' started with command: #{@command} "
    node = json['Node'] ? json['Node']['Name'] : Docker.url
    info = info + "on host: #{node} "
    info = info + "with name: #{json['Name']}."
    puts info

    attach_opts = {
      stderr: true,
      stdout: true,
      logs: true,
      follow: true,
    }

    container.streaming_logs(attach_opts) do |stream, chunk|
      # stream == :stdout || :stderr so objectify it and .puts to proper
      # output
      Object.const_get(stream.to_s.upcase).puts chunk
    end
  rescue => err
    exit_code = 3
    STDERR.puts "#{err.class} - #{err.message}"
  ensure
    if secret_plugin.respond_to? :remove
      puts 'Removing secrets plugin data...'
      secret_plugin.remove
      puts 'Done removing secrets plugin data.'
    end

    if container
      json = container.refresh!.json
      puts 'Removing container...'
      container.remove
      puts 'Done removing container.'
    end

    # We have json from the container and there wasn't an error already
    if json && exit_code == 0
      exit_code = json['State']['ExitCode']
      if err_msg = json['State']['Error'] and !err_msg.empty?
        STDERR.puts "Container '#{@image}' failed with exit code #{exit_code}. "\
                    "Message: #{err_msg}"
      end
    end

    if debug? && json
      puts "JSON from Container:"
      pp json
    end

    MemFs.deactivate!

    exit exit_code
  end

  def host_from_image
    host = @image.split('/').first
    host if host =~ /[a-z0-9]*(\.?[a-z0-9]+)\.[a-z]{2,5}(:[0-9]{1,5})?(\/.)?$/ix
  end

  def creds
    ret = {}

    if username = (ENV['RD_CONFIG_DOCKER_REGISTRY_USERNAME'] ||
                   @config['docker']['config.json']['auths'][host_from_image]['username'] rescue nil)
      ret['username'] = username
    end

    if password = (ENV['RD_CONFIG_DOCKER_REGISTRY_PASSWORD'] ||
                   @config['docker']['config.json']['auths'][host_from_image]['password'] rescue nil)
      ret['password'] = password
    end

    ret
  end

  def pull_image
    if force_pull? || !Docker::Image.exist?(@image)
      puts "Pulling image #{@image}"
      Docker::Image.create({'fromImage' => @image}, creds)
    end
  end

  def before_run
    PLUGINS.each do |plugin|
      klass = Object.const_get plugin
      klass.before_run if klass.respond_to? :before_run
    end
  end

  def setup_connection
    @hostnames.shuffle.find do |hst|
      begin
        hst = "#{@protocol}://#{hst}#{@node_port}"
        Timeout.timeout 2 do
          if @key_pem && @ca_pem && @cert_pem
            {
              'cert.pem' => @cert_pem,
              'ca.pem' => @ca_pem,
              'key.pem' => @key_pem,
            }.each do |name, contents|
              File.open(name, 'w') { |file| file.write contents }
            end
            Docker.options = {
              client_cert: 'cert.pem',
              client_key: 'key.pem',
              ssl_ca_file: 'ca.pem',
              ssl_verify_peer: false,
              scheme: 'https'
            }
          end

          Docker.url = hst
          Docker.ping =~ /ok/i
        end
      rescue Timeout::Error, Excon::Error::Socket
        # TODO may want to raise something
        next
      end
    end
  end

end # RundeckDocker


class RundeckDockerMesos < RundeckDockerPlugin

  def initialize
    super
    @tmpfile = Tempfile.new 'RundeckDockerPlugin'
  end

  def run
    mesos_cmd = mesos_runonce_cmd
    if debug?
      STDERR.puts ENV.select{|k,_| k =~ /^RD_/}
      STDERR.puts "Running command: #{mesos_cmd}"
    end

    raise "Command: #{mesos_cmd} failed." unless system mesos_cmd
  rescue => err
    STDERR.puts "#{err.class}: #{err.message}"
    STDERR.puts err.backtrace if debug
    exit $? ? $?.exitstatus : 1
  ensure
    @tmpfile.close if @tmpfile.respond_to? :close
    @tmpfile.unlink if @tmpfile.respond_to? :unlink
  end

  def address
    orig = Socket.do_not_reverse_lookup
    # turn off reverse DNS resolution temporarily
    Socket.do_not_reverse_lookup = true
    addr = UDPSocket.open do |sock|
      # google, should be safe
      sock.connect '64.233.187.99', 1
      sock.addr.last
    end
    "-address=#{addr}"
  ensure
    Socket.do_not_reverse_lookup = orig
  end

  def command
    return unless @command
    "-docker-cmd='#{@command}'"
  end

  def cpus
    cpus = ENV['RD_CONFIG_DOCKER_CPUS']
    return unless cpus
    "-cpus=#{cpus}"
  end

  def debug
    '-logtostderr=true -v=2' if debug?
  end

  def docker_image
    "-docker-image=#{@image}"
  end

  # User passed in ENV vars from rundeck plugin UI.
  def envvars
    return unless @envvars

    env_to_json = @envvars.inject({}){|env, var|
                    # split only on first '='
                    k,v = *var.split(%r{(^\w*)=}).reject(&:empty?)
                    # strip begin and end quotes
                    env[k] = v.gsub /["']$|^["']/, ''
                    env
                  }.to_json

    "-env-vars='{\"env\":#{env_to_json}}'"
  end

  def mem
    mem = ENV['RD_CONFIG_DOCKER_MEMORY']
    return unless mem
    "-mem=#{mem}"
  end

  def mesos_creds
    principal = ENV['RD_CONFIG_DOCKER_MESOS_PRINCIPAL']
    secret = ENV['RD_CONFIG_DOCKER_MESOS_SECRET']

    if principal && !secret or !principal && secret
      raise RundeckDockerMesosPluginInvalidMesosCredConfig
    end

    return unless principal && secret

    @tmpfile.write secret
    @tmpfile.rewind

    "-secret-file=#{@tmpfile.path} -principal=#{principal}"
  end

  def mesos_leader
    hosts = @hostnames
    leader = nil
    hosts.each do |host|
      # In case they input scheme
      hst = host.gsub '^http(s)?://', ''
      uri = URI("http://#{hst}#{@node_port}/redirect")
      http = Net::HTTP.new uri.host, uri.port
      http.read_timeout = 1
      http.open_timeout = 1
      begin
        resp = http.get uri.request_uri
        location = URI(resp['location'])
        leader = "#{location.host}:#{location.port}"
        break
      rescue Net::ReadTimeout, Net::OpenTimeout, SocketError
        next
      end
    end

    raise RundeckDockerMesosPluginNoLeader, hosts unless leader

    "-master=#{leader}"
  end

  def mesos_runonce_cmd
    [
      'mesos-runonce',
      mesos_leader,
      address,
      debug,
      command,
      docker_image,
      cpus,
      mem,
      mesos_creds,
      mesos_user,
      pull_image,
      envvars,
      task_id,
      task_name
    ].compact.join ' '
  end

  def mesos_user
    user = ENV['RD_CONFIG_DOCKER_MESOS_USER']
    return unless user
    "-user=#{user}"
  end

  def pull_image
    "-force-pull=#{force_pull?}"
  end

  def task_id
    "-task-id='rd-#{ENV['RD_JOB_EXECID'] || 'unknown-exec-id'}'"
  end

  def task_name
    job_name = ENV['RD_JOB_NAME'] || 'unknown-name'
    full_job_name = if group = ENV['RD_JOB_GROUP']
                      group + '/' + job_name
                    else
                      job_name
                    end
    name = [
      'Rundeck',
      ENV['RD_JOB_PROJECT'] || 'unknown-project',
      full_job_name,
      ENV['RD_JOB_ID'] || 'unknown-job-id'
    ].join ':'

    "-task-name='#{name}'"
  end

end # RundeckDockerMesos

