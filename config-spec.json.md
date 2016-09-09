# Description
Describes valid JSON to enter into rundeck's key storage as a "Private Key".
See http://rundeck.org/docs/manual/configure.html#key-storage to understand how
to enter this json as a private key. The file can be used for mesos, docker,
and secret storage mechanism sensitive config bits E.g. passwords, certs, etc.


# Configuration
In order to be able to use this, you have to enter the following into your
project's configuration file:
```
project.plugin.WorkflowNodeStep.docker.docker_config_json=path/to/config.json
```

# Spec version 1.0.0
The following is an example of what the JSON spec is for version 1.0.0.

```json
{
        "version":"1.0.0",

        "nodes":{
                "RD_NODE_NAME":{
                        "docker":{
                                "ca.pem":"ca.pem contents joined by '\n' E.g. -----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
                                "cert.pem":"cert.pem contents joined by '\n' E.g. -----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
                                "key.pem":"key.pem contents joined by '\n' E.g. -----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----"
                        }
                }
        },

        "global":{
                "mesos":{
                        "principal":"principal",
                        "secret":"secret"
                },
                "secret_storage":{
                        "username":"username",
                        "password":"password"
                },
                "docker":{
                        "config.json":{
                                "auths":{
                                        "hub.docker.com":{
                                                "username":"username",
                                                "password":"password"
                                        }
                                }
                        }
                }
        }
}
```

All keys that are UPPERCASED are variables. `RD_NODE_NAME` corresponds to that
variable defined in the `env` of the execution environment. See:
http://rundeck.org/docs/developer/plugin-development.html#how-script-plugin-providers-are-invoked.
Basically if you have a resource model source with a top level key of
`my.host.com` then the value of `RD_NODE_NAME` in the JSON should be
`my.host.com` so that mapping of these config bits can merge properly into the
desired host to execute against.

The `docker` hash can have 4 different keys of `ca.pem`, `cert.pem`,
`key.pem`, and `config.json`. `ca.pem` will be the contents of a `ca.pem` used
for authentication to a protected docker daemon. The same is true for
`cert.pem`, and `key.pem`. `config.json` will contain a hash of the exact
contents of your ~/.docker/config.json as JSON, not as a string.

The `mesos` has can have 2 different  keys of `principal` and `secret` which
correspond to the same in mesos. See:
http://mesos.apache.org/documentation/latest/authentication/ for details.

The logic in the JSON is basically `global.deep_merge nodes[rd_node_name]` so
that the local config bits will override global, and global will be there if we
can't find anything defined for `nodes[rd_node_name]`. So in the above example,
I should be able to access the hub.docker.com password by doing
`config['docker']['config.json']['auths']['hub.docker.com']['password']`.
