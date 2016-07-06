require 'json'
require 'socket'
require 'uri'
require 'net/http'
require 'docker'
require 'pp'

old_constants = Object.constants

# Implement this class if you want to retrieve secrets, docs to follow...
class RundeckDockerSecretsPlugin; end

$:.unshift './'
Dir.glob('plugins/*rb').each do |plugin|
  require plugin
end

PLUGINS = Object.constants - old_constants

class RundeckDockerPluginError < StandardError; end

class RundeckDockerPluginNoLeader < RundeckDockerPluginError
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

class RundeckDockerPluginMissingNodePort < RundeckDockerPluginError
  def message
    'Nothing to do. Please select one node with port defined.'
  end
end

class RundeckDockerPluginMissingDockerImage < RundeckDockerPluginError
  def message
    'Must have docker image specified.'
  end
end

class RundeckDockerPluginInvalidMesosCredConfig < RundeckDockerPluginError
  def message
    'Must have mesos secret AND principal defined.'
  end
end


# Responsible for interface to docker
class RundeckDocker
  def initialize
    @node_port = ENV['RD_NODE_PORT'] ? ":#{ENV['RD_NODE_PORT']}" : nil
    @image = ENV['RD_CONFIG_DOCKER_IMAGE']
    @command = ENV['RD_CONFIG_DOCKER_COMMAND']
    @protocol = ENV['RD_NODE_PROTOCOL']
    @envvars = (envvars = ENV['RD_CONFIG_DOCKER_ENV_VARS'] and envvars.split("\n"))
  end

  def creds
    ret = {}
    ret['username'] = ENV['RD_CONFIG_DOCKER_REGISTRY_USERNAME'] if ENV['RD_CONFIG_DOCKER_REGISTRY_USERNAME']
    ret['password'] = ENV['RD_CONFIG_DOCKER_REGISTRY_PASSWORD'] if ENV['RD_CONFIG_DOCKER_REGISTRY_PASSWORD']
    ret
  end

  def force_pull?
    ENV['RD_CONFIG_DOCKER_PULL_IMAGE'] == 'true'
  end

  def pull_image
    if force_pull? || !Docker::Image.exist?(@image)
      puts "Pulling image #{@image}"
      Docker::Image.create({'fromImage' => @image}, creds)
    end
  end

  def debug?
    ENV['RD_JOB_LOGLEVEL'] == 'DEBUG'
  end

  def before_run
    PLUGINS.each do |plugin|
      klass = Object.const_get plugin
      klass.before_run if klass.respond_to? :before_run
    end
  end

  def run
    before_run
    exit_code = nil

    set_host
    pull_image

    create_hash = {
      'Image' => @image,
    }
    @envvars and create_hash['Env'] = @envvars
    @command and create_hash['Cmd'] = @command.split
    secret_plugin = nil
    if secret_klass = Object.const_get(:RundeckDockerSecretsPlugin)
      secret_plugin = secret_klass.new
      if secret_plugin.respond_to? :secrets_config
        create_hash.merge! secret_plugin.secrets_config
      end
    end

    container = Docker::Container.create create_hash

    container.start
    json = container.json

    info = "Container '#{@image}' started with command: #{@command} "
    info = info + "on host: #{json['Node']['Name']} " if json['Node']
    info = info + "with name: #{json['Name']}."
    puts info

    if debug?
      puts "JSON from Container:"
      pp json
    end

    mechanism = json['State']['Running'] ? :attach : :streaming_logs

    attach_opts = {
      stderr: true,
      stdout: true,
      logs: true,
    }

    container.send(mechanism, attach_opts) do |stream, chunk|
      # stream == :stdout || :stderr so objectify it and .puts to proper
      # output
      Object.const_get(stream.to_s.upcase).puts chunk
    end
  rescue Docker::Error::DockerError => err
    exit_code = 3
    STDERR.puts "Error from docker: #{err.class} - #{err}"
  rescue => err
    exit_code = 4
    STDERR.puts "Unhandled error: #{err.class} - #{err}"
  ensure
    if secret_plugin.respond_to? :remove
      puts 'Removing secrets plugin data...'
      secret_plugin.remove
      puts 'Done removing secrets plugin data.'
    end

    if container
      puts 'Removing container...'
      container.remove
      puts 'Done removing container.'
    end

    if json && !exit_code
      exit_code = json['State']['ExitCode']
      if err_msg = json['State']['Error'] and !err_msg.empty?
        STDERR.puts "Container '#{@image}' failed with exit code #{exit_code}. "\
                    "Message: #{err_msg}"
      end
    end
    exit exit_code
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

  def set_host
    hostnames.each do |hst|
      begin
        hst = "#{@protocol}://#{hst}#{@node_port}"
        Timeout.timeout 2 do
          Docker.url = hst
          if Docker.ping =~ /ok/i
            puts "Connected to docker at: #{hst}"
            return
          end
        end
      rescue Timeout::Error
        # TODO may want to raise something
        next
      end
    end
  end

end # RundeckDocker

class RundeckDockerPlugin

  ALLOWABLE_TYPES = %w[mesos docker]

  def initialize tmpfile
    @docker_plugin_type = ENV['RD_NODE_DOCKERPLUGINTYPE']
    @node_port = ENV['RD_NODE_PORT'] ? ":#{ENV['RD_NODE_PORT']}" : nil
    @image = ENV['RD_CONFIG_DOCKER_IMAGE']
    @tmpfile = tmpfile
    sanity_check
  end

  def address
    orig = Socket.do_not_reverse_lookup
    # turn off reverse DNS resolution temporarily
    Socket.do_not_reverse_lookup =true
    addr = UDPSocket.open do |sock|
      # google, should be safe
      sock.connect '64.233.187.99', 1
      sock.addr.last
    end
    "-address=#{addr}"
  ensure
    Socket.do_not_reverse_lookup = orig
  end

  def cmd
    case @docker_plugin_type
    when 'mesos'
      mesos_runonce
    when 'docker'
      RundeckDocker.new.run
    end
  end

  def command
    command = ENV['RD_CONFIG_DOCKER_COMMAND']
    return unless command
    "-docker-cmd='#{command}'"
  end

  def cpus
    cpus = ENV['RD_CONFIG_DOCKER_CPUS']
    return unless cpus
    "-cpus=#{cpus}"
  end

  def debug
    '-logtostderr=true -v=2' if ENV['RD_JOB_LOGLEVEL'] == 'DEBUG'
  end

  def docker_image
    "-docker-image=#{@image}"
  end

  # User passed in ENV vars from rundeck plugin UI.
  def envvars
    env_vars = ENV['RD_CONFIG_DOCKER_ENV_VARS']
    return unless env_vars

    env_to_json = env_vars.split("\n").inject({}){|env, var|
                    # split only on first '='
                    k,v = *var.split(%r{(^\w*)=}).reject(&:empty?)
                    # strip begin and end quotes
                    env[k] = v.gsub /["']$|^["']/, ''
                    env
                  }.to_json

    "-env-vars='{\"env\":#{env_to_json}}'"
  end

  def force_pull?
    ENV['RD_CONFIG_DOCKER_PULL_IMAGE'] == 'true'
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

  def mem
    mem = ENV['RD_CONFIG_DOCKER_MEMORY']
    return unless mem
    "-mem=#{mem}"
  end

  def mesos_creds
    principal = ENV['RD_CONFIG_DOCKER_MESOS_PRINCIPAL']
    secret = ENV['RD_CONFIG_DOCKER_MESOS_SECRET']

    if principal && !secret or !principal && secret
      raise RundeckDockerPluginInvalidMesosCredConfig
    end

    return unless principal && secret

    @tmpfile.write secret
    @tmpfile.rewind

    "-secret-file=#{@tmpfile.path} -principal=#{principal}"
  end

  def mesos_leader
    hosts = hostnames
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

    raise RundeckDockerPluginNoLeader, hosts unless leader

    "-master=#{leader}"
  end

  def mesos_runonce
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

  def sanity_check
    @docker_plugin_type or raise RundeckDockerPluginMissingPluginType
    ALLOWABLE_TYPES.include? @docker_plugin_type or
      raise RundeckDockerPluginInvalidPluginType, ALLOWABLE_TYPES
    @image or raise RundeckDockerPluginMissingDockerImage
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

end

