# rundeck-docker-plugin
Rundeck interface for running docker containers against nodes. Nodes need to
have an attribute of `dockerPluginType` defined which is a String of either
`mesos`, or `docker`. Users may then configure this plugin's form
elements to run their container on any / all of the selected nodes that have a
`dockerPluginType` defined. It is also expected that the node have a `port`
defined as well like:
```yaml
mesos-host:
  port: 5050
  dockerPluginType: mesos
  ...
docker-host:
  port: 2375
  dockerPluginType: docker
  ...
swarm-host:
  port: 4000
  dockerPluginType: docker
  ...
```

# Screenshot of plugin UI

![workflow-step](screenshot/workflow-step.png)

# Usage
To get this working you will need:

- A rundeck server
- Ruby version >= 2.0.x installed
- Ruby gem 'docker-api' v ~> 1.28.0
- Ruby gem 'memfs' v ~> 0.5.0
- [mesos-runonce](https://github.com/yp-engineering/mesos-runonce) v1.0.4
  available in the rundeck server's $PATH
- This plugin's .zip file either from the
  [releases](https://github.com/yp-engineering/rundeck-docker-plugin/releases)
  (Coming soon), or by cloning and running `make`.
- Installing this plugin's .zip file into the rundeck server's plugin path
  (usually $RDECK_BASE/libext).

# Rundeck project level settings

DEPRECATED - Please use key storage for this data with a valid config.json
explained by the [config-spec.json](config-spec.json.md).

To configure your credentials for talking to a mesos that has authentication
turned on set the following:

```java
project.plugin.WorkflowNodeStep.docker.docker_mesos_principal=principal
project.plugin.WorkflowNodeStep.docker.docker_mesos_secret=secret
```

To configure your credentials for pulling private images set the following:

```java
project.plugin.WorkflowNodeStep.docker.docker_registry_password=password
project.plugin.WorkflowNodeStep.docker.docker_registry_username=username
```

TODO: This secrets integration is...a bit secret in that it is not well
documented / thought out yet. Examples are needed for this some day.
To configure a secret(s) store that has authentication set the following:

```java
project.plugin.WorkflowNodeStep.docker.docker_secret_store_password=password
project.plugin.WorkflowNodeStep.docker.docker_secret_store_username=username
```
