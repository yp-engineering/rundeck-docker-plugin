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
- [mesos-runonce](https://github.com/yp-engineering/mesos-runonce) v1.0.4
  available in the rundeck server's $PATH
- This plugin's .zip file either from the
  [releases](https://github.com/yp-engineering/rundeck-docker-plugin/releases)
  (Coming soon), or by cloning and running `make`.
- Installing this plugin's .zip file into the rundeck server's plugin path
  (usually $RDECK_BASE/libext).
