#!/usr/bin/env bash
clear
#
# Copyright (c) https://github.com/freqstart/freqstart/
#
# You are welcome to improve the code. If you just use the script and like it,
# remember that it took a lot of time, testing and also money for infrastructure.
# You can contribute by donating to the following wallets:
#
# BTC 1M6wztPA9caJbSrLxa6ET2bDJQdvigZ9hZ
# ETH 0xb155f0F64F613Cd19Fb35d07D43017F595851Af5
# BSC 0xb155f0F64F613Cd19Fb35d07D43017F595851Af5
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
# OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly FS_VERSION='v3.0.9'

readonly FS_NAME="freqstart"
readonly FS_TMP="/tmp/${FS_NAME}"
readonly FS_SYMLINK="/usr/local/bin/${FS_NAME}"
readonly FS_FILE="${FS_NAME}.sh"
readonly FS_GIT="https://raw.githubusercontent.com/freqstart/freqstart/stable"
readonly FS_URL="${FS_GIT}/${FS_NAME}.sh"
FS_DIR="$(dirname "$(readlink --canonicalize-existing "${0}" 2> /dev/null)")"
readonly FS_DIR
readonly FS_PATH="${FS_DIR}/${FS_FILE}"
readonly FS_DIR_USER_DATA="${FS_DIR}/user_data"

FS_USER="$(id -u -n)"
readonly FS_USER
FS_USER_ID="$(id -u)"
readonly FS_USER_ID

readonly FS_AUTO_SCHEDULE="0 0 * * *"
readonly FS_AUTO_SCRIPT="${FS_PATH} --auto"

readonly FS_NETWORK="${FS_NAME}_network"
readonly FS_NETWORK_SUBNET='172.35.0.0/16'
readonly FS_NETWORK_GATEWAY='172.35.0.1'

readonly FS_PROXY_BINANCE="${FS_NAME}_binance"
readonly FS_PROXY_BINANCE_YML="${FS_DIR}/${FS_PROXY_BINANCE}.yml"
readonly FS_PROXY_BINANCE_IP='172.35.0.253'

readonly FS_PROXY_KUCOIN="${FS_NAME}_kucoin"
readonly FS_PROXY_KUCOIN_YML="${FS_DIR}/${FS_PROXY_KUCOIN}.yml"
readonly FS_PROXY_KUCOIN_IP='172.35.0.252'

readonly FS_NGINX="${FS_NAME}_nginx"
readonly FS_NGINX_YML="${FS_DIR}/${FS_NGINX}.yml"
readonly FS_NGINX_DIR="${FS_DIR}/nginx"
readonly FS_NGINX_CONF="${FS_NGINX_DIR}/conf/frequi.conf"
readonly FS_NGINX_HTPASSWD="${FS_NGINX_DIR}/conf/.htpasswd"

readonly FS_FREQUI="${FS_NAME}_frequi"
readonly FS_FREQUI_JSON="${FS_DIR_USER_DATA}/${FS_FREQUI}.json"
readonly FS_FREQUI_YML="${FS_DIR}/${FS_FREQUI}.yml"

readonly FS_STRATEGIES="${FS_NAME}_strategies"
readonly FS_STRATEGIES_FILE="${FS_STRATEGIES}.json"
readonly FS_STRATEGIES_URL="${FS_GIT}/${FS_STRATEGIES_FILE}"
readonly FS_STRATEGIES_PATH="${FS_DIR}/${FS_STRATEGIES_FILE}"
readonly FS_STRATEGIES_CUSTOM_PATH="${FS_DIR}/${FS_STRATEGIES}_custom.json"

readonly FS_REGEX="(${FS_PROXY_KUCOIN}|${FS_PROXY_BINANCE}|${FS_NGINX}|${FS_FREQUI})"

FS_HASH="$(xxd -l 8 -ps /dev/urandom)"
readonly FS_HASH

trap _fsCleanup_ EXIT
trap '_fsErr_ "${FUNCNAME:-.}" ${LINENO}' ERR

######################################################################
# DOCKER
######################################################################

_docker_version() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local docker_image="${1}"
  local docker_repo="${docker_image%:*}"
  local docker_tag="${docker_image##*:}"
  local docker_token=''
  local docker_version_hub=''
  local docker_version_local=''
  
  docker_token="$(curl --connect-timeout 10 -s \
  "https://auth.docker.io/token?scope=repository:${docker_repo}:pull&service=registry.docker.io"  \
  | jq -r '.token' \
  || _fsMsgError_ 'Cannot retrieve docker token.')"

  docker_version_hub="$(curl --connect-timeout 10 -s \
  --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  --header "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  --header "Authorization: Bearer ${docker_token}" \
  -v --silent "https://registry-1.docker.io/v2/${docker_repo}/manifests/${docker_tag}" 2>&1 \
  | grep -oE 'etag: "(.*)"' \
  | sed 's,\",,g' \
  | sed 's,etag: ,,' \
  || _fsMsgError_ 'Cannot retrieve docker manifest.')"
  
  if docker inspect --type=image "${docker_image}" > /dev/null; then
    docker_version_local="$(docker inspect --format='{{index .RepoDigests 0}}' "${docker_image}" | cut -d '@' -f 2)"
  fi

  if [[ ! "${docker_version_hub}" = "${docker_version_local}" ]]; then
    _fsMsg_ "Downloading latest \"${docker_image}\" docker image..."
    
    docker pull "${docker_image}" > /dev/null \
    || _fsMsgError_ "Cannot download latest \"${docker_image}\" docker image."
    
    _fsMsg_ "Installed latest \"${docker_image}\" docker image."
  fi
}

_docker_ps() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local docker_name="${1}"
  local docker_mode="${2:-}" # optional: all
  local docker_ps=''
  
  # credit: https://serverfault.com/a/733498; https://stackoverflow.com/a/44731522
  if [[ "${docker_mode}" = "all" ]]; then
    docker_ps="$(docker ps -a --format '{{.Names}}' | grep -ow "${docker_name}" || true)"
  else
    docker_ps="$(docker ps --format '{{.Names}}' | grep -ow "${docker_name}" || true)"
  fi

  if [[ -n "${docker_ps}" ]]; then
    echo 0 # docker container exist
  else
    echo 1 # docker container does not exist
  fi
}

_docker_name() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local docker_id="${1}"
  local docker_name=''

  docker_name="$(docker inspect --format="{{.Name}}" "${docker_id}" | sed "s,\/,," || true)"

  if [[ -n "${docker_name}" ]]; then
    echo "${docker_name}"
  fi
}

_docker_remove() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local docker_name="${1}"

  # stop and remove active and non-active docker container
  if [[ "$(_docker_ps "${docker_name}" "all")" -eq 0 ]]; then
    docker update --restart=no "${docker_name}" > /dev/null
    docker stop "${docker_name}" > /dev/null
    docker rm -f "${docker_name}" > /dev/null

    if [[ "$(_docker_ps "${docker_name}" "all")" -eq 0 ]]; then
      _fsMsgWarning_ "Cannot remove container: ${docker_name}"
    else
      _fsMsg_ "Container removed: ${docker_name}"
    fi
  fi
}

_fsDockerReset_() {
  _fsMsgTitle_ "SETUP: RESET"
  
  if [[ "$(_fsCaseConfirmation_ "Reset all docker projects and networks?")" -eq 0 ]]; then
    _fsCrontabRemove_ "${FS_AUTO_SCRIPT}"
    
    # credit: https://stackoverflow.com/a/69921248
    docker ps -a -q 2> /dev/null | xargs -I {} docker rm -f {} 2> /dev/null || true
    _fsDockerPrune_
  else
    _fsMsg_ 'Skipping...'
  fi
}

_fsDockerPrune_() {
    # remove all unused containers, networks and images
    docker system prune --all --force > /dev/null || true
}

_fsProjectImages_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _project="${1}"
  local _images=()
  local _imagesDeduped=()
  local _image=''
  
  # credit: https://stackoverflow.com/a/39612060
  while read -r; do
    _images+=( "$REPLY" )
  done < <(grep -vE '^\s+#' "${_project}" \
  | grep 'image:' \
  | sed "s,\s,,g" \
  | sed "s,image:,,g" \
  || true)
  
  if (( ${#_images[@]} )); then
    while read -r; do
      _imagesDeduped+=( "$REPLY" )
    done < <(_array_dedupe "${_images[@]}")
    
    for _image in "${_imagesDeduped[@]}"; do
      _docker_version "${_image}"
    done
  fi
}

_fsProjectStrategies_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _project="${1}"
  local _strategies=()
  local _strategy=''
  local _strategiesDedupe=()
  local _strategyDedupe=''
  local _dirs=()
  local _dirsDedupe=()
  local _dir=''
  local _path=''
  local _pathFound=1
  local _file=''
  local _error=0
  
  # download or update implemented strategies
  while read -r; do
    _strategies+=( "$REPLY" )
  done < <(grep -vE '^\s+#' "${_project}" \
  | grep "strategy" \
  | grep -v "strategy-path" \
  | sed "s,\=,,g" \
  | sed "s,\",,g" \
  | sed "s,\s,,g" \
  | sed "s,\-\-strategy,,g" || true)
  
  if (( ${#_strategies[@]} )); then
    while read -r; do
      _strategiesDedupe+=( "$REPLY" )
    done < <(_array_dedupe "${_strategies[@]}")
    
    # validate optional strategy paths in project file
    while read -r; do
      _dirs+=( "$REPLY" )
    done < <(grep -vE '^\s+#' "${_project}" \
    | grep "strategy-path" \
    | sed "s,\=,,g" \
    | sed "s,\",,g" \
    | sed "s,\s,,g" \
    | sed "s,\-\-strategy-path,,g" \
    | sed "s,^/[^/]*,${FS_DIR}," || true)
    
    # add default strategy path
    _dirs+=( "${FS_DIR_USER_DATA}/strategies" )
    
    while read -r; do
      _dirsDedupe+=( "$REPLY" )
    done < <(_array_dedupe "${_dirs[@]}")
    
    for _strategyDedupe in "${_strategiesDedupe[@]}"; do
      _fsStrategy_ "${_strategyDedupe}"
      
      for _dir in "${_dirsDedupe[@]}"; do
        _path="${_dir}/${_strategyDedupe}.py"
        _file="${_path##*/}"
        
        if [[ -f "${_path}" ]]; then
          _pathFound=0
          break
        fi
      done
      
      if [[ "${_pathFound}" -eq 1 ]]; then
        _fsMsg_ 'Strategy file not found: '"${_file}"
        _error=$((_error+1))
      fi
      
      _pathFound=1
    done
  fi
  
  if [[ "${_error}" -eq 0 ]]; then
    echo 0
  else
    echo 1
  fi
}

_fsProjectConfigs_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _project="${1}"
  local _configs=()
  local _config=''
  local _configsDedupe=()
  local _configDedupe=''
  local _path=''
  local _error=0
  
  while read -r; do
    _configs+=( "$REPLY" )
  done < <(grep -vE '^\s+#' "${_project}" \
  | grep -e "\-\-config" -e "\-c" \
  | sed "s,\=,,g" \
  | sed "s,\",,g" \
  | sed "s,\s,,g" \
  | sed "s,\-\-config,,g" \
  | sed "s,\-c,,g" \
  | sed "s,\/freqtrade\/,,g" || true)
  
  if (( ${#_configs[@]} )); then
    while read -r; do
      _configsDedupe+=( "$REPLY" )
    done < <(_array_dedupe "${_configs[@]}")
    
    for _configDedupe in "${_configsDedupe[@]}"; do
      _path="${FS_DIR}/${_configDedupe}"
      if [[ ! -f "${_path}" ]]; then
        _fsMsg_ "Config file does not exist: ${_path##*/}"
        _error=$((_error+1))
      fi
    done
  fi
  
  if [[ "${_error}" -eq 0 ]]; then
    echo 0
  else
    echo 1
  fi
}

_fsProjectCompose_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _project="${1}"
  local _projectFile="${_project##*/}"
  local _projectFileName="${_projectFile%.*}"
  local _projectStrategies=1
  local _projectConfigs=1
  local _containers=()
  local _container=''
  local _containerActive=''
  local _containerName=''
  local _containerCmd=''
  local _containerLogfile=''
  local _containersPs=()
  local _containerPs=''
  local _containerInactive=0
  local _compose=1
  local _error=0

  [[ ! -f "${_project}" ]] && _fsMsgError_ "File not found: ${_projectFile}"
  
  if [[ ! "${_projectFile}" =~ $FS_REGEX ]]; then
    if [[ "$(_fsCaseConfirmation_ "Compose project: ${_projectFile}")" -eq 0 ]]; then
      _compose=0
    fi
  else
    _fsMsg_ "Compose project: ${_projectFile}"
    _compose=0
  fi

  if [[ "${_compose}" -eq 0 ]]; then
    _projectStrategies="$(_fsProjectStrategies_ "${_project}")"
    _projectConfigs="$(_fsProjectConfigs_ "${_project}")"
    _fsProjectImages_ "${_project}"
    
    [[ "${_projectStrategies}" -eq 1 ]] && _error=$((_error+1))
    [[ "${_projectConfigs}" -eq 1 ]] && _error=$((_error+1))
    
    if [[ "${_error}" -eq 0 ]]; then
      # create docker network; credit: https://stackoverflow.com/a/59878917
      docker network create --subnet="${FS_NETWORK_SUBNET}" --gateway "${FS_NETWORK_GATEWAY}" "${FS_NETWORK}" > /dev/null 2> /dev/null || true

      docker-compose -f "${_project}" -p "${_projectFileName}" up --no-start > /dev/null 2> /dev/null || true

      while read -r; do
        _containers+=( "$REPLY" )
      done < <(docker-compose -f "${_project}" -p "${_projectFileName}" ps -q)

      for _container in "${_containers[@]}"; do
        _containerName="$(_docker_name "${_container}")"
        _containerActive="$(_docker_ps "${_containerName}")"
        
        # connect container to docker network
        if [[ "${_containerName}" = "${FS_PROXY_BINANCE}" ]]; then
          docker network connect --ip "${FS_PROXY_BINANCE_IP}" "${FS_NETWORK}" "${_containerName}" > /dev/null 2> /dev/null || true
        elif [[ "${_containerName}" = "${FS_PROXY_KUCOIN}" ]]; then
          docker network connect --ip "${FS_PROXY_KUCOIN_IP}" "${FS_NETWORK}" "${_containerName}" > /dev/null 2> /dev/null || true
        else
          docker network connect "${FS_NETWORK}" "${_containerName}" > /dev/null 2> /dev/null || true
        fi
        
        # set restart to no to filter faulty containers
        docker update --restart=no "${_containerName}" > /dev/null
          
        # start container
        if [[ "${_containerActive}" -eq 1 ]]; then
          _fsMsg_ "Starting container: ${_containerName}"
          docker start "${_containerName}" > /dev/null
        else
          if [[ "$(_fsCaseConfirmation_ "Restart container: ${_containerName}")" -eq 0 ]]; then
            docker restart "${_containerName}" > /dev/null
          else
            _fsMsg_ "Skipping..."
          fi
        fi
      done
      
      echo 0
    else
      echo 1
    fi
  else
    echo 1
  fi
}

_fsProjectRun_() {
  [[ $# -lt 2 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _project="${1}"
  local _projectService="${2}"
  local _projectFile="${_project##*/}"
  local _projectFileName="${_projectFile%.*}"
  
  if [[ -f "${_project}" ]]; then
    _fsProjectImages_ "${_project}"
    
    docker-compose -f "${_project}" -p "${_projectFileName}" run --rm "${_projectService}"
  else
    _fsMsgError_ "File not found: ${_projectFile}"
  fi
}

_fsProjectValidate_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _project="${1}"
  local _projectFile="${_project##*/}"
  local _projectFileName="${_projectFile%.*}"
  local _containers=()
  local _container=''
  local _containerActive=''
  local _containerName=''
  local _error=0
  local _cors=''

  [[ ! -f "${_project}" ]] && _fsMsgError_ "File not found: ${_projectFile}"
  
  _fsMsg_ "Validate project: ${_projectFile}"
  
  if [[ -f "${FS_FREQUI_JSON}" ]]; then
    _cors="$(cat "${FS_FREQUI_JSON}" | \
    grep "CORS_origins" | \
    grep -oE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" \
    || true)"
  fi
  
  while read -r; do
    _containers+=( "$REPLY" )
  done < <(docker-compose -f "${_project}" -p "${_projectFileName}" ps -q)

  for _container in "${_containers[@]}"; do
    _containerName="$(_docker_name "${_container}")"
    _containerActive="$(_docker_ps "${_containerName}")"
    
    if [[ "${_containerActive}" -eq 0 ]]; then
      _fsMsg_ 'Container is active: '"${_containerName}"
      
      # set restart to unless-stopped
      docker update --restart=unless-stopped "${_containerName}" > /dev/null
    
      if [[ ! "${_containerName}" =~ $FS_REGEX ]]; then
        # get container command
        _containerCmd="$(docker inspect --format="{{.Config.Cmd}}" "${_container}" \
        | sed "s,\[, ,g" \
        | sed "s,\], ,g" \
        | sed "s,\",,g" \
        | sed "s,\=, ,g" \
        | sed "s,\/freqtrade\/,,g")"
        
        if [[ -n "${_containerCmd}" ]]; then
          _containerApiJson="$(echo "${_containerCmd}" | grep -o "${FS_FREQUI_JSON##*/}" || true)"

          if [[ -n "${_containerApiJson}" ]]; then
            if [[ "$(_docker_ps "${FS_FREQUI}")" -eq 0 ]]; then
              _fsMsg_ "API url: https://${_cors}/${FS_NAME}/${_containerName}"
            else
              _fsMsgWarning_ "FreqUI is not active!"
            fi
          fi
        fi
      fi
    else
      _fsMsgWarning_ 'Container is not active: '"${_containerName}"
      _docker_remove "${_containerName}"
      _error=$((_error+1))
    fi
  done
  
  
  if [[ "${_error}" -eq 0 ]]; then
    echo 0
  else
    echo 1
  fi
}

_fsProjectQuit_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _project="${1}"
  local _projectFile="${_project##*/}"
  local _projectFileName="${_projectFile%.*}"
  local _containers=()
  local _container=''
  local _containerName=''
  local _quit=0
  
  [[ ! -f "${_project}" ]] && _fsMsgError_ "File not found: ${_projectFile}"
  
  while read -r; do
    _containers+=( "$REPLY" )
  done < <(docker-compose -f "${_project}" -p "${_projectFileName}" ps -q)
  
  for _container in "${_containers[@]}"; do
    _containerName="$(_docker_name "${_container}")"
    
    if [[ "$(_docker_ps "${_containerName}")" -eq 0 ]]; then
      _quit=$((_quit+1))
    fi
  done
  
  if [[ "${_quit}" -eq 0 ]]; then
    _fsMsg_ "No active containers in: ${_projectFile}"
    echo 0
  elif [[ "$(_fsCaseConfirmation_ "Quit active containers in: ${_projectFile}")" -eq 1 ]]; then
    echo 1
  else
    for _container in "${_containers[@]}"; do
      _containerName="$(_docker_name "${_container}")"
      _docker_remove "${_containerName}"
    done
    
    echo 0
  fi
}

_fsProjects_() {
  local _projects=()
  local _project=''
  local _projectsFilter=("$@")
  local _validateProjects=()
  local _validateProject=''
  local _crontabProjects=()
  local _crontabProjectsList=''
  
  # find docker project files in script root
  readarray -d '' _projects < <(find "${FS_DIR}" -maxdepth 1 -name "*.yml" -print0)
  
  if (( ${#_projects[@]} )); then
    if [[ "${FS_OPTS_QUIT}" -eq 0 ]]; then
      # quit projects
      _fsMsgTitle_ "PROJECTS: QUIT"

      for _project in "${_projects[@]}"; do
        if [[ ! "${_project##*/}" =~ $FS_REGEX ]]; then
          if [[ "$(_fsProjectQuit_ "${_project}")" -eq 0 ]]; then
            _crontabProjects+=("${_project##*/}")
          fi
        fi
      done
      
      if (( ${#_crontabProjects[@]} )); then
        _crontabProjectsList="${_crontabProjects[*]}"
        _fsCrontabModify_ "a" "${FS_AUTO_SCHEDULE}" "${FS_AUTO_SCRIPT}" $_crontabProjectsList
      fi
    else
      # compose projects
      _fsMsgTitle_ "PROJECTS: COMPOSE"

      for _project in "${_projects[@]}"; do
        if (( ${#_projectsFilter[@]} )); then
          if [[ "$(_fsArrayIn_ "${_project##*/}" "${_projectsFilter[@]}")" -eq 0 ]]; then
            if [[ "$(_fsProjectCompose_ "${_project}")" -eq 0 ]]; then
              _validateProjects+=("${_project}")
            fi
          fi
        elif [[ ! "${_project##*/}" =~ $FS_REGEX ]]; then
          if [[ "$(_fsProjectCompose_ "${_project}")" -eq 0 ]]; then
            _validateProjects+=("${_project}")
          fi
        fi
      done
      
      _fsMsgTitle_ "PROJECTS: VALIDATE"

      if (( ${#_validateProjects[@]} )); then
        # validate projects
        _fsCdown_ 30 "for any errors..."
        
        for _validateProject in "${_validateProjects[@]}"; do
          if [[ "$(_fsProjectValidate_ "${_validateProject}")" -eq 0 ]]; then
            if [[ ! "${_validateProject##*/}" =~ $FS_REGEX ]]; then
              _crontabProjects+=("${_validateProject##*/}")
            fi
          fi
        done

        if (( ${#_crontabProjects[@]} )); then
          _crontabProjectsList="${_crontabProjects[*]}"
          _fsCrontabModify_ "e" "${FS_AUTO_SCHEDULE}" "${FS_AUTO_SCRIPT}" $_crontabProjectsList
        fi
      else
        _fsMsg_ "No projects to validate."
      fi
    fi
    
    _fsDockerPrune_
  else
    _fsMsg_ "No projects found."
  fi
}

######################################################################
# SETUP
######################################################################

_fsSetup_() {
  _fsSetupPrerequisites_
  _fsSetupUser_
  _fsSetupDocker_
  _fsSetupFreqtrade_
  _fsSetupProxyBinance_
  _fsSetupProxyKucoin_
  _fsSetupTailscale_
  _fsSetupFrequi_
  _fsSetupFinish_
}


_fsSetupPrerequisites_() {  
  _fsMsgTitle_ "SETUP: PREREQUISITES"

  # create the strategy config
  while true; do
    if [[ ! -f "${FS_STRATEGIES_PATH}" ]]; then
      _fsMsg_ "Downloading strategies config..."
      _fsDownload_ "${FS_STRATEGIES_URL}" "${FS_STRATEGIES_PATH}" > /dev/null
    else
      _fsMsg_ "Strategies config is installed."
      break
    fi
  done
  
  # install and validate all required packages
  _packages "curl" "cron" "jq" "ufw" "openssl" "systemd-container" "uidmap" "dbus-user-session" "docker-compose"
}

_fsSetupUser_() {
  local	_userSudo=''
  local	_userSudoer=''
  local	_userSudoerFile=''
  local _userTmp=''
  local _userTmpDir=''
  local _userTmpDPath=''
  local _getDocker="${FS_DIR}/get-docker-rootless.sh"
  
  _fsMsgTitle_ "SETUP: USER"
  
  _userSudoer="${FS_USER} ALL=(ALL:ALL) NOPASSWD: ALL"
  _userSudoerFile="/etc/sudoers.d/${FS_USER}"
  
  # validate if current user is root
  if [[ "${FS_USER_ID}" -eq 0 ]]; then
    _fsMsg_ "Create a new user or log in to an existing non-root user."
    
    while true; do
      read -rp '? Username: ' _userTmp
      
      if [[ -z "${_userTmp}" ]]; then
        _fsCaseEmpty_
      else
        if [[ "$(_fsCaseConfirmation_ "Is the username \"${_userTmp}\" correct?")" -eq 0 ]]; then
          # validate if user exist
          if id -u "${_userTmp}" >/dev/null 2>&1; then
            _fsMsg_ "User \"${_userTmp}\" already exist."
            
            if [[ "$(_fsCaseConfirmation_ "Login to user \"${_userTmp}\" now?")" -eq 0 ]]; then
              break
            else
              _userTmp=''
            fi
          else
            _fsMsg_ "User \"${_userTmp}\" does not exist."
            
            if [[ "$(_fsCaseConfirmation_ "Create user \"${_userTmp}\" now?")" -eq 0 ]]; then
              sudo adduser --gecos '' "${_userTmp}"
              break
            else
              _userTmp=''
            fi
          fi
        else
          _userTmp=''
        fi
      fi
    done
    
    # validate if user exist
    if id -u "${_userTmp}" >/dev/null 2>&1; then            
      # add user to sudoer file
      echo "${_userTmp} ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${_userTmp}" > /dev/null
      
      _userTmpDir="$(bash -c "cd ~$(printf %q "${_userTmp}") && pwd")/${FS_NAME}"
      _userTmpPath="${_userTmpDir}/${FS_NAME}.sh"
      
      mkdir -p "${_userTmpDir}"
      
      # copy freqstart to new user home
      mv "${FS_PATH}" "${_userTmpDir}/${FS_FILE}"
      mv "${FS_STRATEGIES_PATH}" "${_userTmpDir}/${FS_STRATEGIES_FILE}"
      mv "${FS_DIR}/.git" "${_userTmpDir}/.git"

      sudo chown -R "${_userTmp}":"${_userTmp}" "${_userTmpDir}"
      sudo chmod +x "${_userTmpPath}"
      
      # lock password of root user
      if [[ "$(_fsCaseConfirmation_ "Disable password for \"${FS_USER}\" user (recommended)?")" -eq 0 ]]; then
        sudo usermod -L "${FS_USER}"
      fi
      
      # remove scriptlock and symlink
      rm -rf "${FS_TMP}"
      sudo rm -f "${FS_SYMLINK}"
      
      _fsMsgTitle_ "CONTINUE SETUP WITH FOLLOWING COMMAND: ${_userTmpDir}/${FS_FILE} --setup"

      sudo machinectl shell "${_userTmp}@" # machinectl is needed to set $XDG_RUNTIME_DIR properly
      exit 0 # force exit needed
    else
      _fsMsgError_ "User does not exist: ${_userTmp}"
    fi
  else
    while true; do
      if ! sudo grep -q "${_userSudoer}" "${_userSudoerFile}" 2> /dev/null; then
        _fsMsg_ "Activating sudo for user: ${FS_USER}"
        echo "${_userSudoer}" | sudo tee "${_userSudoerFile}" > /dev/null
      else
        _fsMsg_ "Sudo is active for user: ${FS_USER}"
        break
      fi
    done
  fi
}

_fsSetupDocker_() {
  local _userBashrc="$(getent passwd "${FS_USER}" | cut -d: -f6)/.bashrc"
  local _getDocker="${FS_DIR}/get-docker.sh"
  local _getDockerUrl="https://get.docker.com/rootless"
  local _count=0

  _fsMsgTitle_ "SETUP: DOCKER (ROOTLESS)"

  # validate if linger is set for current user
  while true; do
    if ! docker info 2> /dev/null | grep -q 'rootless'; then
      [[ $_count -gt 0 ]] && _fsMsgError_ "Error while installing docker (rootless)."

      _fsMsg_ "Installing docker (rootless)..."
      
      sudo systemctl --user stop docker 2> /dev/null || true
      sudo rm -f "/home/${FS_USER}/bin/dockerd" 2> /dev/null || true
      sudo systemctl stop docker.socket docker.service 2> /dev/null || true
      sudo systemctl disable --now docker.socket docker.service 2> /dev/null  || true
      sudo rm -f "/var/run/docker.sock" 2> /dev/null || true

      _fsDownload_ "${_getDockerUrl}" "${_getDocker}" > /dev/null
      sudo chmod +x "${_getDocker}"
      sh "${_getDocker}" > /dev/null # must be executed as non-root
      rm -f "${_getDocker}"

      _count=$(($_count + 1))
    else
      _fsMsg_ "Docker (rootless) is installed."
      break
    fi
  done

  while true; do
    if ! sudo loginctl show-user "${FS_USER}" 2> /dev/null | grep -q 'Linger=yes'; then
      _fsMsg_ "Enabling auto-restart of docker (rootless)..."
      systemctl --user enable docker
      sudo loginctl enable-linger "${FS_USER}"
    else
      _fsMsg_ "Auto-restart of docker (rootless) is enabled."
      break
    fi
  done
}

_fsSetupFreqtrade_() {
  # FREQTRADE; credit: https://github.com/freqtrade/freqtrade

  local _yml="${FS_DIR}/${FS_NAME}_freqtrade.yml"
  
  _fsMsgTitle_ "SETUP: FREQTRADE"

  while true; do
    if [[ ! -d "${FS_DIR_USER_DATA}" ]]; then
      _fsMsg_ "Creating \"user_data\" directory..."
      
      _fsFileCreate_ "${_yml}" \
      "---" \
      "version: '3'" \
      "services:" \
      "  freqtrade:" \
      "    image: freqtradeorg/freqtrade:latest" \
      "    container_name: freqtrade" \
      "    volumes:" \
      "      - \"${FS_DIR_USER_DATA}:/freqtrade/user_data\"" \
      "    command: >" \
      "      create-userdir" \
      "      --userdir /freqtrade/${FS_DIR_USER_DATA##*/}" \
      
      # create user_data folder
      _fsProjectRun_ "${_yml}" "freqtrade"
      
      rm -f "${_yml}"
    else
      _fsMsg_ "Directory \"user_data\" exist."
      break
    fi
  done
}

_fsSetupProxyBinance_() {
  # BINANCE-PROXY; credit: https://github.com/nightshift2k/binance-proxy

  _fsMsgTitle_ "SETUP: BINANCE PROXY"
  
  while true; do
    if [[ "$(_docker_ps "${FS_PROXY_BINANCE}")" -eq 1 ]]; then
      if [[ "$(_fsCaseConfirmation_ "Install proxy for: Binance")" -eq 0 ]]; then
        # binance proxy json file; note: sudo because of freqtrade docker user
        _fsFileCreate_ "${FS_DIR_USER_DATA}/${FS_PROXY_BINANCE}.json" \
        '{' \
        '    "exchange": {' \
        '        "name": "binance",' \
        '        "ccxt_config": {' \
        '            "enableRateLimit": false,' \
        '            "urls": {' \
        '                "api": {' \
        '                    "public": "http://'"${FS_PROXY_BINANCE_IP}"':8990/api/v3"' \
        '                }' \
        '            }' \
        '        },' \
        '        "ccxt_async_config": {' \
        '            "enableRateLimit": false' \
        '        }' \
        '    }' \
        '}'
        
        # binance proxy futures json file; note: sudo because of freqtrade docker user
        _fsFileCreate_ "${FS_DIR_USER_DATA}/${FS_PROXY_BINANCE}_futures.json" \
        '{' \
        '    "exchange": {' \
        '        "name": "binance",' \
        '        "ccxt_config": {' \
        '            "enableRateLimit": false,' \
        '            "urls": {' \
        '                "api": {' \
        '                    "public": "http://'"${FS_PROXY_BINANCE_IP}"':8991/api/v3"' \
        '                }' \
        '            }' \
        '        },' \
        '        "ccxt_async_config": {' \
        '            "enableRateLimit": false' \
        '        }' \
        '    }' \
        '}'
        
        # binance proxy project file
        _fsFileCreate_ "${FS_PROXY_BINANCE_YML}" \
        "---" \
        "version: '3'" \
        "services:" \
        "  ${FS_PROXY_BINANCE}:" \
        "    image: nightshift2k/binance-proxy:latest" \
        "    container_name: ${FS_PROXY_BINANCE}" \
        "    command: >" \
        "      --port-spot=8990" \
        "      --port-futures=8991" \
        "      --verbose" \
        
        _fsProjects_ "${FS_PROXY_BINANCE_YML##*/}"
      else
        _fsMsg_ "Skipping..."
        break
      fi
    else
      _fsMsg_ "Binance proxy is active."
      _fsMsg_ "Add: --config /freqtrade/user_data/${FS_PROXY_BINANCE}.json"
      break
    fi
  done
}

_fsSetupProxyKucoin_() {
  # KUCOIN-PROXY; credit: https://github.com/mikekonan/exchange-proxy
  
  local image=''
  local machine=''
  
  machine="$(_architecture_machine)"
 
  case ${machine} in
    x86_64)
      image='amd64'
    ;;
  esac

  _fsMsgTitle_ "SETUP: KUCOIN PROXY"
  
  while true; do
    if [[ "$(_docker_ps "${FS_PROXY_KUCOIN}")" -eq 1 ]]; then
      if [[ "$(_fsCaseConfirmation_ "Install proxy for: Kucoin")" -eq 0 ]]; then
        # kucoin proxy json file; note: sudo because of freqtrade docker user
        _fsFileCreate_ "${FS_DIR_USER_DATA}/${FS_PROXY_KUCOIN}.json" \
        '{' \
        '    "exchange": {' \
        '        "name": "kucoin",' \
        '        "ccxt_config": {' \
        '            "enableRateLimit": false,' \
        '            "timeout": 60000,' \
        '            "urls": {' \
        '                "api": {' \
        '                    "public": "http://'"${FS_PROXY_KUCOIN_IP}"':8980/kucoin",' \
        '                    "private": "http://'"${FS_PROXY_KUCOIN_IP}"':8980/kucoin"' \
        '                }' \
        '            }' \
        '        },' \
        '        "ccxt_async_config": {' \
        '            "enableRateLimit": false,' \
        '            "timeout": 60000' \
        '        }' \
        '    }' \
        '}'
        
        # kucoin proxy project file
        _fsFileCreate_ "${FS_PROXY_KUCOIN_YML}" \
        "---" \
        "version: '3'" \
        "services:" \
        "  ${FS_PROXY_KUCOIN}:" \
        "    image: mikekonan/exchange-proxy:latest-${image}" \
        "    container_name: ${FS_PROXY_KUCOIN}" \
        "    command: >" \
        "      -port 8980" \
        "      -verbose 1"
        
        _fsProjects_ "${FS_PROXY_KUCOIN_YML##*/}"
      else
        _fsMsg_ "Skipping..."
        break
      fi
    else
      _fsMsg_ "Kucoin proxy is active."
      _fsMsg_ "Add: --config /freqtrade/user_data/${FS_PROXY_KUCOIN}.json"
      break
    fi
  done
}

_fsSetupTailscale_() {
  local _download="https://tailscale.com/install.sh"
  local _setup="${FS_DIR}/tailscale.sh"
  
  _fsMsgTitle_ "SETUP: TAILSCALE (VPN)"
  
  while true; do
    if ! tailscale ip -4 > /dev/null 2> /dev/null; then
      _fsMsg_ "Setup account first: https://tailscale.com"
      
      if [[ "$(_fsCaseConfirmation_ "Install tailscale now?")" -eq 1 ]]; then
        _fsMsg_ "Skipping..."
        break
      else
        _fsDownload_ "${_download}" "${_setup}" >/dev/null
        sh "${_setup}"
        rm -f "${_setup}"
        sudo tailscale up
      fi
    else
      _fsMsg_ "Tailscale is installed: $(tailscale ip -4)"
      
      while true; do
        if ! sudo ufw status | grep -q "tailscale0"; then
          if [[ "$(_fsCaseConfirmation_ "Restrict all access incl. SSH to Tailscale (recommended)?")" -eq 0 ]]; then
            # ufw allow access over tailscale
            sudo ufw --force reset > /dev/null
            sudo ufw allow in on tailscale0 > /dev/null
            sudo ufw allow 41641/udp > /dev/null
            sudo ufw default deny incoming > /dev/null
            sudo ufw default allow outgoing > /dev/null
            sudo ufw --force enable > /dev/null
            sudo service ssh restart
          else
            _fsMsg_ "Skipping..."
            break
          fi
        else
          _fsMsg_ "Access is restricted to tailscale."
          _fsMsg_ "Disable key expiration (recommended):"
          _fsMsg_ "https://tailscale.com/kb/1028/key-expiry/"
          break
        fi
      done
      
      break
    fi
  done
}

# FREQUI

_fsSetupFrequi_() {
  local _tailscaleIp="$(tailscale ip -4 2> /dev/null || true)"
  local _sysctl="${FS_NGINX_DIR}/99-${FS_NAME}.conf"
  local _sysctlSymlink="/etc/sysctl.d/${_sysctl##*/}"
  local _jwt=''
  local _login=''
  local _username=''
  local _password=''
  local _bypass=''
  local _sslKey="${FS_NGINX_DIR}/nginx-selfsigned.key"
  local _sslCert="${FS_NGINX_DIR}/nginx-selfsigned.crt"
  local _sslParam="${FS_NGINX_DIR}/dhparam.pem"
  local _sslConf="${FS_NGINX_DIR}/self-signed.conf"
  local _sslConfParam="${FS_NGINX_DIR}/ssl-params.conf"
  local image=''
  local machine=''
  
  _fsMsgTitle_ "SETUP: FREQUI"

  machine="$(_architecture_machine)"
 
  case ${machine} in
    x86_64)
      image='amd64'
    ;;
    aarch64)
      image='arm64v8'
    ;;
  esac
    
  while true; do
    if [[ -z "${_tailscaleIp}" ]]; then
      _fsMsg_ "Installation of tailscale is required. Restart setup!"
      break
    fi
    
    if [[ "$(_docker_ps "${FS_FREQUI}")" -eq 1 ]] || [[ "$(_docker_ps "${FS_NGINX}")" -eq 1 ]]; then
      if [[ "$(_fsCaseConfirmation_ "Install FreqUI now?")" -eq 1 ]]; then
        _fsMsg_ "Skipping..."
        break
      fi
    else
      _fsMsg_ "FreqUI is accessible via: https://${_tailscaleIp}"
      _fsMsg_ "Add: --config /freqtrade/user_data/${FS_FREQUI_JSON##*/}"
      break
    fi
    
    mkdir -p "${FS_NGINX_DIR}/conf"
    
    # set unprivileged ports to start with 80 for rootles nginx proxy
    while true; do
      if [[ "$(_fsSymlinkValidate_ "${_sysctlSymlink}")" -eq 1 ]]; then
        _fsMsg_ "Allowing unprivileged ports for rootless nginx proxy..."
        
        _fsFileCreate_ "${_sysctl}" \
        "# ${FS_NAME}" \
        '# set unprivileged ports to start with 80 for rootless nginx proxy' \
        'net.ipv4.ip_unprivileged_port_start = 80'

        if [[ "$(_fsSymlinkCreate_ "${_sysctl}" "${_sysctlSymlink}")" -eq 0 ]]; then
          sudo sysctl -p "${_sysctlSymlink}" > /dev/null
        fi
      else
        _fsMsg_ "Unprivileged ports for rootless nginx proxy allowed."
        break
      fi
    done

    # generate login data for api and nginx
    while true; do
      if [[ -f "${FS_NGINX_HTPASSWD}" ]] && [[ -f "${FS_FREQUI_JSON}" ]]; then
        if [[ "$(_fsCaseConfirmation_ "Skip creating new login data?")" -eq 0 ]]; then
          _fsMsg_ "Skipping..."
          break
        else
          rm -f "${FS_NGINX_HTPASSWD}"
          rm -f "${FS_FREQUI_JSON}"
        fi
      else
        _fsMsg_ "Create login data:"
      fi
      
      _jwt="$(_fsRandomBase64UrlSafe_ 32)"
      _login="$(_fsLogin_)"
      _username="$(_fsLoginDataUsername_ "${_login}")"
      _password="$(_fsLoginDataPassword_ "${_login}")"

      # create htpasswd for nginx
      while true; do
        if [[ -f "${FS_NGINX_HTPASSWD}" ]]; then
          _fsMsg_ "Login for Nginx is created."
          break
        else
          sh -c "echo -n ${_username}':' > ${FS_NGINX_HTPASSWD}"
          sh -c "openssl passwd ${_password} >> ${FS_NGINX_HTPASSWD}"
        fi
      done
      
      # create frequi json for bots
      while true; do
        if [[ -f "${FS_FREQUI_JSON}" ]]; then
          _fsMsg_ "FreqUI config is created."
          break
        else
          _fsFileCreate_ "${FS_FREQUI_JSON}" \
          '{' \
          '    "api_server": {' \
          '        "enabled": true,' \
          '        "listen_ip_address": "0.0.0.0",' \
          '        "listen_port": 9999,' \
          '        "verbosity": "error",' \
          '        "enable_openapi": false,' \
          '        "jwt_secret_key": "'"${_jwt}"'",' \
          '        "CORS_origins": ["'"${_tailscaleIp}"'"],' \
          '        "username": "'"${_username}"'",' \
          '        "password": "'"${_password}"'"' \
          '    }' \
          '}'
        fi
      done
      
      break
    done

    # create nginx conf for ip ssl; credit: https://serverfault.com/a/1060487
    _fsFileCreate_ "${FS_NGINX_CONF}" \
    "map \$http_cookie \$rate_limit_key {" \
    "    default \$binary_remote_addr;" \
    '    "~__Secure-rl-bypass='"${_bypass}"'" "";' \
    "}" \
    "limit_req_status 429;" \
    "limit_req_zone \$rate_limit_key zone=auth:10m rate=1r/m;" \
    "server {" \
    "    listen 0.0.0.0:80;" \
    "    location / {" \
    "        return 301 https://\$host\$request_uri;" \
    "    }" \
    "}" \
    "server {" \
    "    listen 0.0.0.0:443 ssl;" \
    "    include /etc/nginx/snippets/${_sslConf##*/};" \
    "    include /etc/nginx/snippets/${_sslConfParam##*/};" \
    "    location / {" \
    "        resolver 127.0.0.11;" \
    "        set \$_pass ${FS_FREQUI}:9999;" \
    "        auth_basic \"Restricted\";" \
    "        auth_basic_user_file /etc/nginx/conf.d/${FS_NGINX_HTPASSWD##*/};" \
    "        limit_req zone=auth burst=20 nodelay;" \
    "        add_header Set-Cookie \"__Secure-rl-bypass='${_bypass}';Max-Age=31536000;Domain=\$host;Path=/;Secure;HttpOnly\";" \
    "        proxy_pass http://\$_pass;" \
    "        proxy_set_header X-Real-IP \$remote_addr;" \
    "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
    "        proxy_set_header Host \$host;" \
    "        proxy_set_header X-NginX-Proxy true;" \
    "        proxy_redirect off;" \
    "    }" \
    "    location /api {" \
    "        return 400;" \
    "    }" \
    "    location ~ ^/(${FS_NAME})/([^/]+)(.*) {" \
    "        resolver 127.0.0.11;" \
    "        set \$_pass \$2:9999\$3;" \
    "        proxy_pass http://\$_pass;" \
    "        proxy_set_header X-Real-IP \$remote_addr;" \
    "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
    "        proxy_set_header Host \$host;" \
    "        proxy_set_header X-NginX-Proxy true;" \
    "        proxy_redirect off;" \
    "    }" \
    "}" \
    
    _fsFileCreate_ "${_sslConf}" \
    "ssl_certificate /etc/ssl/certs/${_sslCert##*/};" \
    "ssl_certificate_key /etc/ssl/private/${_sslKey##*/};"
    
    _fsFileCreate_ "${_sslConfParam}" \
    "ssl_protocols TLSv1.2;" \
    "ssl_prefer_server_ciphers on;" \
    "ssl_dhparam /etc/nginx/${_sslParam##*/};" \
    "ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;" \
    "ssl_ecdh_curve secp384r1; # Requires nginx >= 1.1.0" \
    "ssl_session_timeout 10m;" \
    "ssl_session_cache shared:SSL:10m;" \
    "ssl_session_tickets off; # Requires nginx >= 1.5.9" \
    "ssl_stapling on; # Requires nginx >= 1.3.7" \
    "ssl_stapling_verify on; # Requires nginx => 1.3.7" \
    "resolver 8.8.8.8 8.8.4.4 valid=300s;" \
    "resolver_timeout 5s;" \
    "add_header X-Frame-Options DENY;" \
    "add_header X-Content-Type-Options nosniff;" \
    "add_header X-XSS-Protection \"1; mode=block\";"
    
    # generate self-signed certificate
    if [[ -f "${_sslKey}" ]]; then
      if [[ "$(_fsCaseConfirmation_ "Skip generating new SSL key?")" -eq 0 ]]; then
        _fsMsg_ "Skipping..."
      else
        rm -f "${_sslKey}"
        rm -f "${_sslCert}"
        rm -f "${_sslParam}"
      fi
    fi
      
    while true; do
      if [[ ! -f "${_sslKey}" ]] || [[ ! -f "${_sslCert}" ]] || [[ ! -f "${_sslParam}" ]]; then        
        rm -f "${_sslKey}"
        rm -f "${_sslCert}"
        rm -f "${_sslParam}"
        
        touch "${_sslParam}"
        
        sh -c "openssl req -x509 -nodes -days 358000 -newkey rsa:2048 -keyout ${_sslKey} -out ${_sslCert} -subj /CN=localhost; openssl dhparam -out ${_sslParam} 4096"
      else
        _fsMsg_ "SSL files exist."
        break
      fi
    done

    # create nginx docker project file
    _fsFileCreate_ "${FS_NGINX_YML}" \
    "version: '3'" \
    "services:" \
    "  ${FS_NGINX}:" \
    "    container_name: ${FS_NGINX}" \
    "    image: ${image}/nginx:stable" \
    "    ports:" \
    "      - \"${_tailscaleIp}:80:80\"" \
    "      - \"${_tailscaleIp}:443:443\"" \
    "    volumes:" \
    "      - \"${FS_NGINX_DIR}/conf:/etc/nginx/conf.d\"" \
    "      - \"${_sslConf}:/etc/nginx/snippets/${_sslConf##*/}\"" \
    "      - \"${_sslConfParam}:/etc/nginx/snippets/${_sslConfParam##*/}\"" \
    "      - \"${_sslParam}:/etc/nginx/${_sslParam##*/}\"" \
    "      - \"${_sslCert}:/etc/ssl/certs/${_sslCert##*/}\"" \
    "      - \"${_sslKey}:/etc/ssl/private/${_sslKey##*/}\""
    
    _fsProjects_ "${FS_NGINX_YML##*/}"
    
    # create frequi docker project file
    _fsFileCreate_ "${FS_FREQUI_YML}" \
    "---" \
    "version: '3'" \
    "services:" \
    "  ${FS_FREQUI}:" \
    "    image: freqtradeorg/freqtrade:stable" \
    "    container_name: ${FS_FREQUI}" \
    "    ports:" \
    "      - \"${_tailscaleIp}:9999:9999\"" \
    "    volumes:" \
    "      - \"${FS_DIR_USER_DATA}:/freqtrade/user_data\"" \
    "    command: >" \
    "      trade" \
    "      --strategy DoesNothingStrategy" \
    "      --strategy-path /freqtrade/user_data/strategies/DoesNothingStrategy" \
    "      --config /freqtrade/user_data/strategies/DoesNothingStrategy/config.json" \
    "      --config /freqtrade/user_data/${FS_FREQUI_JSON##*/}"
    
    _fsProjects_ "${FS_FREQUI_YML##*/}"
  done
}

_fsSetupFinish_() {
  if [[ "$(_fsSymlinkCreate_ "${FS_PATH}" "${FS_SYMLINK}")" -eq 0 ]]; then
    _fsMsgTitle_ "SETUP: FINISH"
    _fsMsg_ "You can now run the script from anywhere with: ${FS_NAME}"
  fi
}

######################################################################
# UTILITY
######################################################################

_fsLogo_() {
  printf -- '%s\n' \
  "    __                  _            _" \
  "   / _|_ _ ___ __ _ ___| |_ __ _ _ _| |_" \
  "  |  _| '_/ -_) _\` (__-\  _/ _\` | '_|  _|" \
  "  |_| |_| \___\__, /___/\__\__,_|_|  \__|" \
  "                 |_|               ${FS_VERSION}" \
  "" >&2
}

_architecture() {
  local kernel=''
  local machine=''
  
  kernel="$(_architecture_kernel)"
  machine="$(_architecture_machine)"
  
  if [[ -z "${kernel}" ]] || [[ -z "${machine}" ]]; then
    _fsMsgError_ "Your OS is not supported. Please open an issue: https://github.com/freqstart/freqstart/issues"
  fi
}

_architecture_kernel() {
  local kernel=''
  local supported=1

  kernel="$(uname -s || true)"
  
  case ${kernel} in
    Linux)
      supported=0
      ;;
  esac
  
  if [[ "${supported}" -eq 0 ]]; then
    echo "${kernel}"
  fi
}

_architecture_machine() {
  local machine=''
  local supported=1

  machine="$(uname -m || true)"
  
  case ${machine} in
    x86_64)
      supported=0
      ;;
    aarch64)
      supported=0
      ;;
    arm)
      if dpkg --print-architecture | grep -q 'arm64'; then
        machine='arm64'
      fi
      ;;
  esac
  
  if [[ "${supported}" -eq 0 ]]; then
    echo "${machine}"
  fi
}

_packages() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local	pkgs=("${@}")
  local pkg=''
  local pkgs_install=()
  local pkg_install=''
  
  for pkg in "${pkgs[@]}"; do
    if [[ "$(_packages_status "${pkg}")" -eq 1 ]]; then 
      pkgs_install+=("${pkg}")
    fi
  done
  
  if (( ${#pkgs_install[@]} )); then
    sudo apt-get update || true
    
    for pkg_install in "${pkgs_install[@]}"; do
      sudo apt-get install -y -q "${pkg_install}"
    done
  fi
}

_packages_install() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local	pkg="${1}"
  
  sudo apt-get install -y -q "${pkg}"
}

_packages_status() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local	pkg="${1}"
  
  if dpkg -s "${pkg}" &> /dev/null; then
      echo 0
  else
      echo 1
  fi
}

_fsStrategy_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _name="${1}"
  local _dir="${FS_DIR_USER_DATA}/strategies/${_name}"
  local _urls=()
  local _urlsDedupe=()
  local _url=''
  local _path=''
  local _download=''
  local _strategies="${FS_STRATEGIES_PATH}"
  
  if [[ -f "${FS_STRATEGIES_CUSTOM_PATH}" ]]; then
    _strategies="${FS_STRATEGIES_CUSTOM_PATH}"
  fi
  
  if [[ -f "${_strategies}" ]]; then
    while read -r; do
    _urls+=( "$REPLY" )
    done < <(jq -r ".${_name}[]?" "${FS_STRATEGIES_PATH}")
        
    if (( ${#_urls[@]} )); then
      while read -r; do
      _urlsDedupe+=( "$REPLY" )
      done < <(_array_dedupe "${_urls[@]}")
    fi
    
    if (( ${#_urlsDedupe[@]} )); then
      # note: sudo because of freqtrade docker user
      sudo mkdir -p "${_dir}"
      
      for _url in "${_urlsDedupe[@]}"; do
        _path="${_dir}/${_url##*/}"
        _download="$(_fsDownload_ "${_url}" "${_path}")"
      done
    else
      _fsMsgWarning_ "Strategy not implemented: ${_name}"
    fi
  else
    _fsMsgError_ "Strategy config file not found!"
  fi
}

_fsFileCreate_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _file="${1}"
  local _input=()
  local _output=''

  shift; _input=("${@}")
  _output="$(printf -- '%s\n' "${_input[@]}")"
  echo "${_output}" | sudo tee "${_file}" > /dev/null
}

_fsDownload_() {
  [[ $# -lt 2 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _url="${1}"
  local _output="${2}"
  local _outputTmp="${FS_TMP}/${FS_HASH}_${_output##*/}"
  
  curl --connect-timeout 10 -fsSL "${_url}" -o "${_outputTmp}" || true

  if [[ ! -s "${_outputTmp}" ]] && [[ -f "${_output}" ]]; then
    _fsMsgWarning_ "Can not get newer file: ${_url}"
    echo 0
  elif [[ -s "${_outputTmp}" ]]; then
    if [[ -f "${_output}" ]]; then
      # only update if temp file is different
      if ! cmp --silent "${_outputTmp}" "${_output}"; then
        sudo cp -a "${_outputTmp}" "${_output}"
        echo 1
      else
        echo 0
      fi
    else
      sudo cp -a "${_outputTmp}" "${_output}"
      echo 1
    fi
  else
    _fsMsgError_ "Download failed: ${_url}"
  fi
}

_fsRandomHex_() {
  local _length="${1:-16}"
  local _string=''
  
  _string="$(xxd -l "${_length}" -ps /dev/urandom)"
  
  echo "${_string}"
}

_fsRandomBase64_() {
  local _length="${1:-24}"
  local _string=''
  
  _string="$(xxd -l "${_length}" -ps /dev/urandom | xxd -r -ps | base64)"
  
  echo "${_string}"
}

_fsRandomBase64UrlSafe_() {
  local _length="${1:-32}"
  local _string=''
  
  _string="$(xxd -l "${_length}" -ps /dev/urandom | xxd -r -ps | base64 | tr -d = | tr + - | tr / _)"
  
  echo "${_string}"
}

_fsErr_() {
  local _error="${?}"
  
  printf -- '%s\n' "Error in ${FS_FILE} in function ${1} on line ${2}" >&2
  exit "${_error}"
}

_fsScriptlock_() {
  local _lockDir="${FS_TMP}/${FS_NAME}.lock"
  
  if [[ -d "${_lockDir}" ]]; then
    # set error to 99 and do not remove tmp dir for debugging
    _fsMsgError_ "Script is already running: rm -rf ${FS_TMP}" 99
  elif ! mkdir -p "${_lockDir}" 2> /dev/null; then
    _fsMsgError_ "Unable to acquire script lock: ${_lockDir}"
  fi
}

_fsCleanup_() {
  local _error="${?}"
  local _userTmp=''
  
  # workaround for freqtrade user_data permissions
  if [[ -d "${FS_DIR_USER_DATA}" ]]; then
    # shellcheck disable=SC2012
    _userTmp="$(ls -ld "${FS_DIR_USER_DATA}" | awk 'NR==1 {print $3}')"
    
    sudo chown -R "${_userTmp}:${FS_USER}" "${FS_DIR_USER_DATA}"
    sudo chmod -R g+w "${FS_DIR_USER_DATA}"
  fi
  
  trap - ERR EXIT SIGINT SIGTERM
  
  if [[ "${_error}" -ne 99 ]]; then
    rm -rf "${FS_TMP}"
    _fsCdown_ 1 'to remove script lock...'
  fi
}

_fsCaseConfirmation_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _question="? ${1} (y/n)"
  local _yesNo=''

  while true; do
    if [[ "${FS_OPTS_AUTO}" -eq 0 ]]; then
      _fsMsg_ "${_question} y"
      _yesNo="y"
    else
      read -rp "${_question} " _yesNo
    fi
    
    case ${_yesNo} in
      [Yy]*)
        echo 0
        break
        ;;
      [Nn]*)
        echo 1
        break
        ;;
      *)
        _fsCaseInvalid_
        ;;
    esac
  done
}

_fsCaseInvalid_() {
  _fsMsg_ 'Invalid response!'
}

_fsCaseEmpty_() {
  _fsMsg_ 'Response cannot be empty!'
}

_fsMsg_() {
  local _msg="${1:-}"
  
  printf -- '%s\n' \
  "  ${_msg}" >&2
}

_fsMsgTitle_() {
  local _msg="${1:-}"
  # 70 chars
  printf -- '%s\n' \
  '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
  "~ ${_msg}" >&2
}

_fsMsgSuccess_() {
  local _msg="${1:-}"
  
  printf -- '%s\n' \
  "+ [SUCCESS] ${_msg}" >&2
}

_fsMsgWarning_() {
  local _msg="${1:-}"
  
  printf -- '%s\n' \
  "! [WARNING] ${_msg}" >&2
}

_fsMsgError_() {
  local _msg="${1:-}"
  local -r _code="${2:-90}"
  
  printf -- '%s\n' \
  '' \
  "! [ERROR] ${_msg}" >&2
  
  exit "${_code}"
}

_fsCdown_() {
  [[ $# -lt 2 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _secs="${1}"; shift
  local _text="${*}"
  
  while [[ "${_secs}" -gt -1 ]]; do
    if [[ "${_secs}" -gt 0 ]]; then
      # shellcheck disable=SC2059 # ignore shellcheck
      printf '\r\033[K< Waiting '"${_secs}"' seconds '"${_text}" >&2
      sleep 0.5
      # shellcheck disable=SC2059 # ignore shellcheck
      printf '\r\033[K> Waiting '"${_secs}"' seconds '"${_text}" >&2
      sleep 0.5
    else
      printf '\r\033[K' >&2
    fi
    : $((_secs--))
  done
}

_fsSymlinkCreate_() {
  [[ $# -lt 2 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _source="${1}"
  local _link="${2}"
  local _error=1
  
  if [[ -f "${_source}" || -d "${_source}" ]]; then
    if [[ "$(_fsSymlinkValidate_ "${_link}")" -eq 1 ]]; then
      sudo ln -sfn "${_source}" "${_link}"
      
      if [[ "$(_fsSymlinkValidate_ "${_link}")" -eq 1 ]]; then
        _fsMsgError_ "Cannot create symlink: ${_link}"
      else
        echo 0
      fi
    else
      echo 0
    fi
  else
    _fsMsgError_ "Symlink source does not exist: ${_source}"
  fi
}

_fsSymlinkValidate_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _link="${1}"
  
  # credit: https://stackoverflow.com/a/36180056
  if [ -L "${_link}" ] ; then
    if [ -e "${_link}" ] ; then
      echo 0
    else
      sudo rm -f "${_link}"
      echo 1
    fi
  elif [ -e "${_link}" ] ; then
    sudo rm -f "${_link}"
    echo 1
  else
    sudo rm -f "${_link}"
    echo 1
  fi
}

_array_dedupe() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local -a _array=()
  local -A _arrayTmp=()
  local _i=''
  
  for _i in "$@"; do
    { [[ -z ${_i} || -n ${_arrayTmp[${_i}]:-} ]]; } && continue
    _array+=("${_i}") && _arrayTmp[${_i}]=x
  done
  
  printf -- '%s\n' "${_array[@]}"
}

_fsArrayIn_() {
  [[ $# -lt 2 ]] && fatal "Missing required argument to ${FUNCNAME[0]}"
  
  # credit: https://github.com/labbots/bash-utility
  local opt
  local OPTIND=1
  local _match=1

  while getopts ":iI" opt; do
    case ${opt} in
      i | I)
        # shellcheck disable=SC2064 # reset nocasematch when function exits
        trap '$(shopt -p nocasematch)' RETURN
        # use case-insensitive regex
        shopt -s nocasematch
        ;;
      *) fatal "Unrecognized option '${1}' passed to ${FUNCNAME[0]}. Exiting." ;;
    esac
  done
  
  shift $((OPTIND - 1))

  local _array_item
  local _value="${1}"
  shift
  
  for _array_item in "$@"; do
    if [[ ${_array_item} =~ ^${_value}$ ]]; then
      _match=0
      break
    fi
  done
  
  if [[ "${_match}" -eq 1 ]]; then
    echo 1
  else
    echo 0
  fi
}

_fsCrontab_() {
  [[ $# -lt 2 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _schedule="${1}"
  local _script="${2}"
  local _cron="${_schedule} ${_script}"
  local _args="${3}"
  
  if [[ -n "${_args}" ]]; then
    _cron="${_cron} ${_args}"
  fi
  
  # credit: https://stackoverflow.com/a/17975418
  ( crontab -l 2> /dev/null | grep -v -F "${_script}" || : ; echo "${_cron}" ) | crontab -
  
  if [[ "$(_fsCrontabValidate_ "${_cron}")" -eq 1 ]]; then
    _fsMsgWarning_ "Cron not set: ${_cron}"
  fi
}

_fsCrontabModify_() {
  [[ $# -lt 3 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"

  local _mode="${1}" # arguments: e (extend); a (abbreviate)
  local _schedule="${2}"
  local _script="${3}"
  shift; shift; shift
  local _args=("${@}")
  local _argsDedupe=()
  local _arg=''

  local _crontab=''
  local _crontabArgs=''
  
  _crontab="$(crontab -l 2> /dev/null | grep -F "${_script}" || true)" # get current crontab
  
  if [[ -n "${_crontab}" ]]; then
    if [[ "${_mode}" = "e" ]]; then # extend current crontab
      while read -r; do
        _args+=( "$REPLY" )
      done < <(echo "${_crontab}" \
      | sed "s,\(.*\)${_script} ,," \
      | sed "s, ,\n,g" || true)
      
      while read -r; do
        _argsDedupe+=( "$REPLY" )
      done < <(_array_dedupe "${_args[@]}")
      
      _crontabArgs="${_argsDedupe[*]}"
    elif [[ "${_mode}" = "a" ]]; then # abbreviate current crontab
      _crontabArgs="$(echo "${_crontab}" \
      | sed "s,\(.*\)${_script} ,," || true)"
      
      for _arg in "${_args[@]}"; do
        _crontabArgs="$(echo "${_crontabArgs}" | sed "s,${_arg},,")"
      done
    fi
  else
    _crontabArgs="${_args[*]}"
  fi
  
  _crontabArgs="$(echo "${_crontabArgs}" | tr -s ' ' | sed "s,^[ ],," | sed "s,[ ]$,,")" # sanitize whitespace
  
  if [[ -n "${_crontabArgs}" ]]; then
    _fsCrontab_ "${_schedule}" "${_script}" "${_crontabArgs}"
  else
    _fsCrontabRemove_ "${_script}"
  fi
}

_fsCrontabRemove_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _cron="${1}"
  if [[ "$(_fsCrontabValidate_ "${_cron}")" -eq 0 ]]; then
    # credit: https://stackoverflow.com/a/17975418
    ( crontab -l 2> /dev/null | grep -v -F "${_cron}" || : ) | crontab -
    
    if [[ "$(_fsCrontabValidate_ "${_cron}")" -eq 0 ]]; then
      _fsMsgWarning_ "Cron not removed: ${_cron}"
    fi
  fi
}

_fsCrontabValidate_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _cron="${1}"
  
  if crontab -l 2> /dev/null | grep -q -F "${_cron}"; then
    echo 0
  else
    echo 1
  fi
}

_fsLogin_() {
  local _username=''
  local _password=''
  local _passwordCompare=''
  
  # create username
  while true; do
    read -rp '  Enter username: ' _username >&2
    
    if [[ -n "${_username}" ]]; then
      if [[ "$(_fsCaseConfirmation_ "Is the username correct: ${_username}")" -eq 0 ]]; then
        break
      else
        _fsMsg_ "Try again!"
      fi
    fi
  done
  
  # create password; NON VERBOSE
  while true; do
    echo -n '  Enter password (ENTRY HIDDEN): ' >&2
    read -rs _password >&2
    echo >&2
    case ${_password} in 
      "")
        _fsCaseEmpty_
        ;;
      *)
        echo -n '  Enter password again (ENTRY HIDDEN): ' >&2
        read -r -s _passwordCompare >&2
        echo >&2
        if [[ ! "${_password}" = "${_passwordCompare}" ]]; then
          _fsMsg_ "The password does not match. Try again!"
          _password=''
          _passwordCompare=''
        else
          break
        fi
        ;;
    esac
  done
  # output only to non-verbose functions to split login data
  echo "${_username}:${_password}"
}

_fsLoginDataUsername_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _username="${1}"
  # shellcheck disable=SC2005
  echo "$(cut -d':' -f1 <<< "${_username}")"
}

_fsLoginDataPassword_() {
  [[ $# -lt 1 ]] && _fsMsgError_ "Missing required argument to ${FUNCNAME[0]}"
  
  local _password="${1}"
  # shellcheck disable=SC2005
  echo "$(cut -d':' -f2 <<< "${_password}")"
}

_fsOptions_() {
  local -r _args=("${@}")
  local _opts
  
  _opts="$(getopt --options q,r,s --long auto:,quit,reset,setup -- "${_args[@]}" 2> /dev/null)" || {
    _fsMsgError_ "Unkown or missing argument."
  }
  
  eval set -- "${_opts}"
  while true; do
    case "${1}" in
      --auto)
        shift
        FS_ARGS_AUTO="$(echo "${@}" | sed "s, \-\-,,")"
        FS_OPTS_AUTO=0
        break
        ;;
      --quit|-q)
        FS_OPTS_QUIT=0
        break
        ;;
      --reset|-r)
        FS_OPTS_RESET=0
        break
        ;;
      --setup|-s)
        FS_OPTS_SETUP=0
        break
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
}

#
# RUNTIME
#

_fsLogo_
_fsScriptlock_

FS_OPTS_AUTO=1
FS_OPTS_QUIT=1
FS_OPTS_RESET=1
FS_OPTS_SETUP=1

FS_ARGS_AUTO=''

_architecture
_fsOptions_ "${@}"

if [[ "${FS_OPTS_RESET}" -eq 0 ]]; then
  _fsDockerReset_
elif [[ "${FS_OPTS_SETUP}" -eq 0 ]]; then
  _fsSetup_
elif [[ "$(_fsSymlinkValidate_ "${FS_SYMLINK}")" -eq 0 ]];then
  _fsProjects_ $FS_ARGS_AUTO
else
  _fsMsgError_ "Finish setup first: ${FS_PATH} --setup"
fi

exit 0