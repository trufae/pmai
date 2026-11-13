# Project boxes

Boxing is off by default. `pmai box create` enables it persistently for a Git
project. Subsequent CLI launches, ACP workers, and Mac app conversations enter
that project's container before loading plugins or running tools. If its engine
or container cannot start, pmai reports an error instead of running locally.

```sh
cd project
pmai box create
pmai                         # automatically enters the project's box
pmai box status
pmai box diff
pmai box apply               # explicit import into the original checkout
pmai box stop                # stops every process, but keeps boxing enabled
pmai box off                 # stops the box and restores local execution
```

The CLI also exposes `/box` with completion and `/help box`. After `/box create`
or `/box on`, restart the CLI to enter the worker. Management commands run on the
host; from inside a box, use a separate host terminal for `pmai box stop`, `off`,
or `apply`. Guest agents cannot call back into host box management.

In the Mac app, use a local folder's **Project Box** menu. Boxed folders show a
box icon. The menu supports creation, enabling/disabling, start/stop, exporting
a diff, applying changes, and removing the container. **Create Box with
Configuration…** explicitly copies a chosen pmai JSON configuration, including
embedded credentials. **Configure in Terminal** opens pmai in the project's
box; configure providers and tools there. The Mac app's host Settings editor
does not modify guest settings. Existing conversations close when changing the
box; active conversations must be stopped first.

## Storage and Git

The default layout is:

```
~/.pmai/box/<id>/box.json        host-owned project policy
~/.pmai/box/<id>/build/          generated image recipe and Linux executable
~/.pmai/box/<id>/home/           isolated guest home, configuration and history
~/.pmai/worktree/<id>/           independent Git checkout
```

`PMAI_HOME` relocates this storage; normal CLI launches also respect `--home`.
For management commands with a custom home, use `PMAI_HOME=/path pmai box ...`.
Project matching follows canonical paths, including subdirectories and launches
from the isolated checkout itself. The checkout is mounted at the original
project's absolute path **inside** the container, so ACP paths remain stable
without exposing the original directory.

Despite the directory name, these are independent clones, not linked Git
worktrees. They do not share writable Git objects, refs, hooks, or configuration
with the source repository. Creation snapshots committed HEAD and removes the
origin remote. Uncommitted edits and untracked/ignored files are not copied.
Submodules and LFS objects are not provisioned automatically.

`diff` includes tracked changes and nonignored new files; it marks new files with
Git's intent-to-add in the guest checkout. `apply` checks the complete binary
patch first and fails on conflicting local edits. It does not merge commits,
execute guest hooks on the host, or run tests on imported code. Review changes
before importing and running them. History remains separate from host chats.

## Image and policy

```sh
pmai box create --engine docker --image ubuntu:24.04 \
  --port 8080:8080 --debug --memory 8g --cpus 4 \
  --config /path/to/guest-config.json

# For a development version or a release unavailable for your engine:
pmai box create --binary /path/to/linux-arm64/pmai
```

The default recipe expects a Debian/Ubuntu-compatible image with `apt-get` and
installs Git, certificates, curl, a C/C++ toolchain and GDB. Supply a compatible
base image or pin it by digest with `--image`. Without `--binary`, pmai downloads
the matching static Linux release for the engine architecture and verifies its
published SHA256 checksum. A supplied binary is trusted explicitly and must run
on the guest OS and architecture. Image creation checks `pmai --version` before
the worker starts. A macOS executable cannot run in a Linux container.

Each project gets a separate container, writable system layer, checkout, home,
and (when online) container network. Child agents and subprocesses inherit the
same environment. Installing packages as container root is supported with a
limited capability set; the container is never privileged and receives neither
the engine socket nor host SSH agent, home, devices, or Git directory. Rootless
Docker/Podman is preferable on Linux; a rootful engine can leave root-owned files
in the isolated checkout. Containers share their underlying kernel, so this is
not a VM-level boundary against hostile code.

- `--network bridge` allows outbound access; it is the default so model APIs and
  package downloads work. It is **not** an egress allowlist or protection against
  exfiltrating source code or credentials available to the guest.
- `--network none` disables external networking, including model APIs. ACP over
  stdio still works. Port publishing is unavailable in this mode.
- `--port HOST:GUEST` publishes TCP on host loopback only. No ports are published
  by default. ACP itself uses `docker exec -i`, without a listening TCP port.
- `--debug` adds `SYS_PTRACE`, retaining the engine's seccomp profile. Debugger
  behavior also depends on the kernel and runtime profile; no blanket unconfined
  or privileged mode is provided.
- Memory, CPU, PID count, and container log limits are enforced. Disk quotas for
  workspace data and installed packages are not implemented.

Without `--config`, the guest starts with standard tools and no copied provider
credentials. Configure it once from its CLI. With `--config`, file paths and
environment-variable references are evaluated inside the guest; host environment
variables and credential files are not automatically copied. Configure remote
ACP/MCP services deliberately: credentials and unrestricted networking can permit
execution on other machines, outside the local container boundary.

Host ACP file access and tool forwarding are disabled for project-box connections,
including when the worker was launched as an ordinary `pmai --acp` command.
For other custom remote wrappers, use `options.isolated: true`.

## Recovery and scope

`start`/`stop` preserve installed packages. `destroy` removes the container and
disables boxing but keeps its checkout, home and image. `on` recreates a removed
container from its image. `rebuild [--binary PATH]` retries image creation and
replaces the container, keeping its checkout/home but losing packages installed
after image creation. It also applies edited `box.json` runtime settings.
Failed provisioning keeps its policy enabled, so the next launch fails closed;
use `rebuild` to retry an image build, or `off` to explicitly return to host execution.

Managed backends currently cover local Docker and Podman on macOS/Linux. SSH
and Vagrant ACP transports can use a box configured **on their worker machine**:

```sh
ssh host 'cd /remote/project && pmai box create'
# Configure the provider with remoteCwd=/remote/project and isolated=true:
ssh -T host 'cd /remote/project && exec pmai --acp'
```

A Vagrant VM works similarly through its SSH connection; disable Vagrant's default
sharing of the original checkout if using it for isolation. Remote image/VM
provisioning, workspace transfer to remote engines, network destination allowlists,
model credential proxies, and native VM backends are not implemented here. Bare
chroot is not advertised as a secure box. An SSH connection alone is not a sandbox.
