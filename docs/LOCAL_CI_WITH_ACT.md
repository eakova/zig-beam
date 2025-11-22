# Run CI Locally with `act`

Use this command to run the CI workflow’s Debug job on your machine (Apple Silicon compatible). It forces amd64 containers and maps all runner labels to a Linux image:

```bash
act workflow_dispatch -W .github/workflows/ci.yml -j test \
  --container-architecture linux/amd64 \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-24.04 \
  -P macos-latest=ghcr.io/catthehacker/ubuntu:act-24.04 \
  -P windows-latest=ghcr.io/catthehacker/ubuntu:act-24.04 \
  --matrix '{"os":"ubuntu-latest","optimize":"Debug"}'
```

Prereqs:
- Docker running locally.
- `act` installed and on your `PATH`.

Tip: put the `-P` and `--container-architecture` flags into `~/.actrc` to avoid retyping. Adjust the `--matrix` entry if you want other targets. 
