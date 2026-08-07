#!/bin/sh
set -eu

HOST=${1:-}
REMOTE_ROOT=/home/chenyn/services/aetherroute-distribution

test -n "$HOST" || {
  echo "usage: $0 user@host" >&2
  exit 64
}

ssh -o BatchMode=yes "$HOST" "
  set -eu
  current=\$(readlink '$REMOTE_ROOT/current')
  case \"\$current\" in releases/*) ;; *) echo 'invalid current release pointer' >&2; exit 1 ;; esac
  current_root='$REMOTE_ROOT'/\"\$current\"
  previous=\$(cat \"\$current_root/PREVIOUS\")
  case \"\$previous\" in releases/*) ;; *) echo 'no valid previous web release is available' >&2; exit 1 ;; esac
  previous_root='$REMOTE_ROOT'/\"\$previous\"
  test -d \"\$previous_root/site\"
  test -f \"\$previous_root/docker-stack.yml\"
  image=\$(docker service inspect aetherroute-web_web --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
  test -n \"\$image\"
  export AETHERROUTE_WEB_IMAGE=\"\$image\"
  export AETHERROUTE_WEB_RELEASE_ROOT=\"\$previous_root\"
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f \"\$previous_root/docker-stack.yml\" config >/dev/null
  elif docker compose version >/dev/null 2>&1; then
    docker compose -f \"\$previous_root/docker-stack.yml\" config >/dev/null
  else
    echo 'no supported Compose configuration validator is installed' >&2
    exit 1
  fi
  docker stack deploy -c \"\$previous_root/docker-stack.yml\" aetherroute-web
  healthy=no
  attempt=0
  while [ \"\$attempt\" -lt 30 ]; do
    status=\$(docker ps \
      --filter label=com.docker.swarm.service.name=aetherroute-web_web \
      --format '{{.Status}}' | head -1)
    case \"\$status\" in *\(healthy\)*) healthy=yes; break ;; esac
    attempt=\$((attempt + 1))
    sleep 2
  done
  test \"\$healthy\" = yes || {
    echo 'previous web release did not become healthy' >&2
    exit 1
  }
  ln -sfn \"\$previous\" '$REMOTE_ROOT/current.next'
  mv -Tf '$REMOTE_ROOT/current.next' '$REMOTE_ROOT/current'
  echo \"Rolled back AetherRoute web distribution to \$previous\"
"
