require 'json'
require 'socket'
require 'uri'
require 'net/http'

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

class RundeckDockerPlugin

  ALLOWABLE_TYPES = %w[mesos swarm]

  def initialize tmpfile
    @docker_plugin_type = ENV['RD_NODE_DOCKERPLUGINTYPE']
    @node_port = ENV['RD_NODE_PORT']
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
    when 'swarm'
      swarm
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
      uri = URI("http://#{hst}:#{@node_port}/redirect")
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
    @node_port or raise RundeckDockerPluginMissingNodePort
    @docker_plugin_type or raise RundeckDockerPluginMissingPluginType
    ALLOWABLE_TYPES.include? @docker_plugin_type or
      raise RundeckDockerPluginInvalidPluginType, ALLOWABLE_TYPES
    @image or raise RundeckDockerPluginMissingDockerImage
  end

  def swarm
    warn 'Not implemented'
  end

  def task_id
    "-task-id='rd-#{ENV['RD_JOB_EXECID'] || 'unknown-exec-id'}'"
  end

  def task_name
    name = [
      'Rundeck',
      ENV['RD_JOB_PROJECT'] || 'unknown-project',
      ENV['RD_JOB_NAME'] || 'unknown-name',
      ENV['RD_JOB_ID'] || 'unknown-job-id'
    ].join ':'

    "-task-name='#{name}'"
  end

end

