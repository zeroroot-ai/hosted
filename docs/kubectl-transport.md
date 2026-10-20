# Exec streams and the kubectl transport

The variable `KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false` makes `kubectl exec`, `attach` and `cp` use SPDY.
The WebSocket transport of kubectl dropped stream bytes, and the exec still exited 0.
This page lists each tool that talks to the Kubernetes API from a runner or a workstation.
It says whether the tool opens an exec stream and how a drop would show.

The variable changes kubectl only.
A tool that links client-go opens its own stream and ignores the variable.

| Tool | Where | Opens an exec stream | How a drop would show |
|---|---|---|---|
| kubectl | each script, make verb and workflow | Yes, with `exec`, `attach` and `cp` | Fixed by the variable. A lost stdin shows as an empty answer, and each secret caller reads back the effect (see below). |
| helm | `scripts/lib/cilium.sh`, `scripts/recreate-*.sh`, the Terraform helm provider | No. It applies objects and polls them. | Not applicable. |
| Terraform providers `kubernetes`, `kubectl`, `helm` | `bootstrap/`, `substrate/` | No. They read and write objects. | Not applicable. |
| cmctl | `test/rotation/exit-test-rotation.sh` | No. `cmctl renew` sets a condition on a Certificate. | Not applicable. |
| velero | inside the Velero pod, run by `kubectl exec` | Through kubectl, so the variable covers it. | The describe output is empty. `backup_resource_list` refuses a list that does not name the release namespace. |
| session-manager-plugin | `scripts/lib/ssm-forward.sh` | No. It carries the API port to the EC2 node. | The API call fails. `ec2_cluster_connect` waits for `kubectl cluster-info` and fails after 120 seconds. |

`kubectl port-forward` is a stream too.
It has its own variable, `KUBECTL_PORT_FORWARD_WEBSOCKETS`, and the repository does not set it.

## Callers that send a secret on stdin

SPDY is better than WebSocket, but a lost stdin is not proven impossible (kubernetes/kubernetes#112834).
Each of these callers checks the effect of what it sent, so a lost stdin fails loud.

| Caller | Check |
|---|---|
| `redis_cli` in `test/rotation/exit-test-rotation.sh` | The reader in the pod exits 97 on an empty read. The caller sends again, 4 times at most. |
| `bao_token_status` in the same file | The same reader. A denial counts only when the token arrived. |
| `session_probe` in the same file | The probe prints `lost` for an empty stdin. An answer that is not `accepted` or `refused` is sent again, then counts as `error`. |
| `bao_kv_list` in `scripts/lib/smoke-probe.sh` | The reader in the pod exits 97 on an empty read and says so on stderr. |
| `bao` in `test/dr/lib/restore-markers.sh` | The command prints a value when it works. `bao_field` sends again on an empty answer and fails by name after 4 tries. |
