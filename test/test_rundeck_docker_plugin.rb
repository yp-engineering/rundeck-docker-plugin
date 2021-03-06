require 'minitest/autorun'
require './docker/contents/rundeck-docker-plugin'

class TestRundeckDockerPlugin < MiniTest::Unit::TestCase
  # Hack request
  class Net::HTTP
    def get *args
      {'location' => 'http://server.com:5050'}
    end
  end

  IP_REGEX = /\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/

  def setup
    ENV.clear
    @tmpfile = Tempfile.new self.class.to_s
    @rdmp = RundeckDockerMesos
  end

  def teardown
    @tmpfile.unlink
  end

  def test_mesos_cmd
    setup_sanity

    hostname 'ypec-prod1-mesos3.wc1.yellowpages.com'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /mesos-runonce/, cmd
    assert_match /-address=#{IP_REGEX}/, cmd
    assert_match /-docker-image=foo/, cmd
    assert_match /-force-pull=false/, cmd
    assert_match /-master=server.com:5050/, cmd
    assert_match /-task-name='Rundeck:unknown-project:unknown-name:unknown-job-id'/, cmd
    assert_match /-task-id='rd-unknown-exec-id'/, cmd

    task_name 'proj', 'name', '1'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-task-name='Rundeck:proj:name:1'/, cmd

    task_name 'proj', 'name', '1', 'group'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match %r{-task-name='Rundeck:proj:group/name:1'}, cmd

    task_name 'proj', 'name', '1', 'nested/group'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match %r{-task-name='Rundeck:proj:nested/group/name:1'}, cmd

    task_id 'yep'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-task-id='rd-yep'/, cmd

    force_pull 'true'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-force-pull=true/, cmd

    principal 'me'
    secret 'secret'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-principal=me/, cmd
    assert_match %r[-secret-file=/tmp/RundeckDockerPlugin], cmd

    log_level 'DEBUG'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-logtostderr=true -v=2/, cmd

    command 'cmd'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-docker-cmd='cmd'/, cmd

    cpus '3'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-cpus=3/, cmd

    mem '2'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-mem=2/, cmd

    mesos_user 'root'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-user=root/, cmd

    envvars 'hi=mom'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"hi":"mom"}}'/, cmd
  end

  def test_sanity_check
    assert_raises RundeckDockerPluginMissingPluginType do
      RundeckDockerPlugin.run
    end

    plugin_type 'crappyclusternotsupported'
    assert_raises RundeckDockerPluginInvalidPluginType do
      RundeckDockerPlugin.run
    end

    plugin_type 'mesos'
    assert_raises RundeckDockerPluginMissingDockerImage do
      RundeckDockerPlugin.run
    end

    docker_image 'foo'
    assert new_rdmp

    plugin_type 'docker'
    assert new_rdmp
  end

  def test_debug
    setup_sanity
    refute new_rdmp.debug
    log_level 'DEBUG'
    assert_equal '-logtostderr=true -v=2', new_rdmp.debug
  end

  def test_hostnames
    setup_sanity

    assert_equal [], new_rdmp.hostnames

    hostname 'cow'
    assert_equal ['cow'], new_rdmp.hostnames

    hostnames '[one,two]'
    assert_equal %w[one two cow], new_rdmp.hostnames

    hostnames 'one,two'
    assert_equal %w[one two cow], new_rdmp.hostnames

    hostnames '[one, two]'
    assert_equal %w[one two cow], new_rdmp.hostnames

    hostnames 'one, two'
    assert_equal %w[one two cow], new_rdmp.hostnames

    hostnames '[,two]'
    assert_equal %w[two cow], new_rdmp.hostnames

    hostnames '[one,]'
    assert_equal %w[one cow], new_rdmp.hostnames
  end

  def test_docker_image
    plugin_type 'mesos'
    assert_raises RundeckDockerPluginMissingDockerImage do
      new_rdmp.docker_image
    end
    docker_image 'foo'
    assert_equal '-docker-image=foo', new_rdmp.docker_image
  end

  def test_cpus
    setup_sanity
    refute new_rdmp.cpus
    cpus '1'
    assert_equal '-cpus=1', new_rdmp.cpus
  end

  def test_mem
    setup_sanity
    refute new_rdmp.mem
    mem '1'
    assert_equal '-mem=1', new_rdmp.mem
  end

  def test_command
    setup_sanity
    refute new_rdmp.command
    command 'cmd ; cow'
    assert_equal "-docker-cmd='cmd ; cow'", new_rdmp.command
  end

  def test_user
    setup_sanity
    refute new_rdmp.mesos_user
    mesos_user '1'
    assert_equal '-user=1', new_rdmp.mesos_user
  end

  def test_pull_image
    setup_sanity

    rdmp = new_rdmp
    refute rdmp.force_pull?
    assert_equal '-force-pull=false', rdmp.pull_image

    force_pull 'true'
    rdmp = new_rdmp
    assert rdmp.force_pull?
    assert_equal '-force-pull=true', rdmp.pull_image
  end

  def test_address
    setup_sanity
    assert_match IP_REGEX, new_rdmp.address
  end

  def test_envvars
    setup_sanity
    hostname 'ypec-prod1-mesos3.wc1.yellowpages.com'
    refute new_rdmp.envvars

    envvars 'cow=boy'
    assert_equal "-env-vars='{\"env\":{\"cow\":\"boy\"}}'", new_rdmp.envvars

    envvars "cow=boy\nbig=\"money 'head' face\"\ncrazy='thing a'\n"
    assert_equal "-env-vars='{\"env\":{\"cow\":\"boy\",\"big\":\"money 'head' face\",\"crazy\":\"thing a\"}}'", new_rdmp.envvars

    envvars 'hi=mom=hi,dad=face'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"hi":"mom=hi,dad=face"}}'/, cmd

    envvars 'under_score=value'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"under_score":"value"}}'/, cmd

    envvars 'UPPER_CASE=value'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"UPPER_CASE":"value"}}'/, cmd

    envvars '123=value'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"123":"value"}}'/, cmd

    envvars '_wieRD_=value'
    cmd = new_rdmp.mesos_runonce_cmd
    assert_match /-env-vars='{"env":{"_wieRD_":"value"}}'/, cmd
  end

  def test_mesos_creds
    setup_sanity
    refute new_rdmp.mesos_creds

    # no secret
    principal 'me'
    assert_raises RundeckDockerMesosPluginInvalidMesosCredConfig do
      new_rdmp.mesos_creds
    end

    # no principal
    principal nil
    secret 'secret'
    assert_raises RundeckDockerMesosPluginInvalidMesosCredConfig do
      new_rdmp.mesos_creds
    end

    principal 'me'
    assert_match /-secret-file=.*-principal=me/, new_rdmp.mesos_creds
  end

  private

  def principal val
    ENV['RD_CONFIG_DOCKER_MESOS_PRINCIPAL'] = val
  end

  def secret val
    ENV['RD_CONFIG_DOCKER_MESOS_SECRET'] = val
  end

  def envvars val
    ENV['RD_CONFIG_DOCKER_ENV_VARS'] = val
  end

  def command val
    ENV['RD_CONFIG_DOCKER_COMMAND'] = val
  end

  def force_pull val
    ENV['RD_CONFIG_DOCKER_PULL_IMAGE'] = val
  end

  def mesos_user val
    ENV['RD_CONFIG_DOCKER_MESOS_USER'] = val
  end

  def mem val
    ENV['RD_CONFIG_DOCKER_MEMORY'] = val
  end

  def cpus val
    ENV['RD_CONFIG_DOCKER_CPUS'] = val
  end

  def setup_sanity
    plugin_type 'mesos'
    docker_image 'foo'
  end

  def docker_image val
    ENV['RD_CONFIG_DOCKER_IMAGE'] = val
  end

  def log_level val
    ENV['RD_JOB_LOGLEVEL'] = val
  end

  def plugin_type val
    ENV['RD_NODE_DOCKERPLUGINTYPE'] = val
  end

  def hostnames vals
    ENV['RD_NODE_HOSTNAMES'] = vals
  end

  def hostname val
    ENV['RD_NODE_HOSTNAME'] = val
  end

  def task_name proj, name, id, group=nil
    ENV['RD_JOB_PROJECT'] = proj
    ENV['RD_JOB_GROUP'] = group
    ENV['RD_JOB_NAME'] = name
    ENV['RD_JOB_ID'] = id
  end

  def task_id val
    ENV['RD_JOB_EXECID'] = val
  end

  def new_rdmp
    @rdmp.new
  end

end
