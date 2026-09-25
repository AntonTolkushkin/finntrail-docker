# Zabbix Agent 2 on the Docker host

`zabbix-agent2` is installed on the Ubuntu host, not in this Compose project.
No `10050` or `10051` ports are published by these containers, so there is no
port conflict.

- TCP `10050` is used for passive checks from Zabbix server/proxy to the agent.
- TCP `10051` is the destination for active checks sent by the agent to the
  Zabbix server/proxy. The host normally does not listen on `10051`.
- Allow inbound `10050/tcp` only from the exact Zabbix server/proxy address.
- Allow outbound `10051/tcp` only to that server/proxy when active checks are
  enabled.
- Do not publish Percona/MySQL (`3306`) or Redis (`6379`) publicly for monitoring.

Recommended host-agent checks:

```text
system.cpu.util
vm.memory.size
vfs.fs.size
net.tcp.service[http,127.0.0.1,8588]
net.tcp.service[http,127.0.0.1,8589]
```

For container metrics, use the official Docker-by-Zabbix-Agent-2 template. It
may require access to `/var/run/docker.sock`; membership in the `docker` group
is effectively root-equivalent, so grant it only to the agent and only when
container-level metrics are actually required.

Example UFW rules (replace the address):

```bash
sudo ufw allow from ZABBIX_SERVER_IP to any port 10050 proto tcp
sudo ufw deny 10050/tcp
```

No Zabbix-specific change is required in `docker-compose.yml`.
