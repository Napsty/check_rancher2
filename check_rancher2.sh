#!/bin/bash 
##########################################################################################
# Script/Plugin: check_rancher2.sh                                                       #
# Author:        Claudio Kuenzler                                                        #
# Official repo: https://github.com/Napsty/check_rancher2                                #
# Documentation: https://www.claudiokuenzler.com/monitoring-plugins/check_rancher2.php   #
# Purpose:       Monitor Rancher 2.x Kubernetes cluster and their containers             #
# Description:   Checks status of resources within the Kubernetes cluster(s) using       #
#                Rancher 2.x API                                                         #
#                                                                                        #
# License :      GNU General Public Licence (GPL) http://www.gnu.org/                    #
# This program is free software; you can redistribute it and/or modify it under the      #
# terms of the GNU General Public License as published by the Free Software Foundation;  #
# either version 2 of the License, or (at your option) any later version.                #
# This program is distributed in the hope that it will be useful, but WITHOUT ANY        #
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A        #
# PARTICULAR PURPOSE.  See the GNU General Public License for more details.              #
# You should have received a copy of the GNU General Public License along with this      #
# program; if not, see <https://www.gnu.org/licenses/>.                                  #
#                                                                                        #
# Copyright 2018-2022 Claudio Kuenzler                                                   #
# Copyright 2020 Matthias Kneer                                                          #
# Copyright 2021,2022 Steffen Eichler                                                    #
# Copyright 2021 lopf                                                                    #
#                                                                                        #
# History:                                                                               #
# 20180629 alpha Started programming of script                                           #
# 20180713 beta1 Public release in repository                                            #
# 20180803 beta2 Check for "type", echo project name in "all workload" check, too        #
# 20180806 beta3 Fix important bug in for loop in workload check, check for 'paused'     #
# 20180906 beta4 Catch cluster not found and zero workloads in workload check            #
# 20180906 beta5 Fix paused check (type 'object' has no elements to extract (arg 5)      #
# 20180921 beta6 Added pod(s) check within a project                                     #
# 20180926 beta7 Handle a workflow in status 'updating' as warning, not critical         #
# 20181107 beta8 Missing pod check type in help, documentation completed                 #
# 20181109 1.0.0 Do not alert for succeeded pods                                         #
# 20190308 1.1.0 Added node(s) check                                                     #
# 20190903 1.1.1 Detect invalid hostname (non-API hostname)                              #
# 20190903 1.2.0 Allow self-signed certificates (-s)                                     #
# 20190913 1.2.1 Detect additional redirect (308)                                        #
# 20200129 1.2.2 Fix typos in workload perfdata (#11) and single cluster health (#12)    #
# 20200523 1.2.3 Handle 403 forbidden error (#15)                                        #
# 20200617 1.3.0 Added ignore parameter (-i)                                             #
# 20210210 1.4.0 Checking specific workloads and pods inside a namespace                 #
# 20210413 1.5.0 Plugin now uses jq instead of jshon, fix cluster error check (#19)      #
# 20210504 1.6.0 Add usage performance data on single cluster check, fix project check   #
# 20210824 1.6.1 Fix cluster and project not found error (#24)                           #
# 20211021 1.7.0 Check for additional node (pressure) conditions (#27)                   #
# 20211201 1.7.1 Fix cluster state detection (#26)                                       #
# 20220610 1.8.0 More performance data, long parameters, other improvements (#31)        #
# 20220729 1.9.0 Output improvements (#32), show workload namespace (#33)                #
# 20220909 1.10.0 Fix ComponentStatus (#35), show K8s version in single cluster check    #
# 20220909 1.10.0 Allow ignoring statuses on workload checks (#29)                       #
##########################################################################################
# (Pre-)Define some fixed variables
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH # Set path
proto=http		# Protocol to use, default is http, can be overwritten with -S parameter
version=1.10.0
##########################################################################################
# functions

# https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/
# convert memory to smallest possible value byte depending on unit
function convertMemory()
{
  local memory_count=$1
  local memory_unit=$2
  
  if [[ ${memory_unit} == "Ei" ]]; then
    memory=$(( ${memory_count} * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 ))
  elif [[ ${memory_unit} == "E" ]]; then
    memory=$(( ${memory_count} * 1000 * 1000 * 1000 * 1000 * 1000 * 1000 ))
  elif [[ ${memory_unit} == "Pi" ]]; then
    memory=$(( ${memory_count} * 1024 * 1024 * 1024 * 1024 * 1024 ))
  elif [[ ${memory_unit} == "P" ]]; then
    memory=$(( ${memory_count} * 1000 * 1000 * 1000 * 1000 * 1000 ))
  elif [[ ${memory_unit} == "Ti" ]]; then
    memory=$(( ${memory_count} * 1024 * 1024 * 1024 * 1024 ))
  elif [[ ${memory_unit} == "T" ]]; then
    memory=$(( ${memory_count} * 1000 * 1000 * 1000 * 1000 ))
  elif [[ ${memory_unit} == "Gi" ]]; then
    memory=$(( ${memory_count} * 1024 * 1024 * 1024 ))
  elif [[ ${memory_unit} == "G" ]]; then
    memory=$(( ${memory_count} * 1000 * 1000 * 1000 ))
  elif [[ ${memory_unit} == "Mi" ]]; then
    memory=$(( ${memory_count} * 1024 * 1024 ))
  elif [[ ${memory_unit} == "M" ]]; then
    memory=$(( ${memory_count} * 1000 * 1000 ))
  elif [[ ${memory_unit} == "Ki" ]]; then
    memory=$(( ${memory_count} * 1024 ))
  elif [[ ${memory_unit} == "k" ]]; then
    memory=$(( ${memory_count} * 1000 ))
  elif [[ ${memory_unit} == "m" ]]; then
    memory=$(( ${memory_count} / 1000 ))
  elif [[ ${memory_unit} == "" ]]; then
    memory=$(( ${memory_count} ))
  else
    echo "UNKNOWN: unexpected memory unit (${memory_unit})."
    exit ${STATE_UNKNOWN}
  fi

  printf $memory
}

# convert cpu to smallest possible value (m = milli CPU) depending on unit
function convertCpu()
{
  local cpu_count=$1
  local cpu_unit=$2
  
  # m = milli CPU
  if [[ ${cpu_unit} == "m" ]]; then
    cpu=${cpu_count}
  # no unit means full cpu
  elif [[ ${cpu_unit} == "" ]]; then
    cpu=$(( ${cpu_count} * 1000 ))
  else
    echo "UNKNOWN: unexpected cpu unit (${cpu_unit})."
    exit ${STATE_UNKNOWN}
  fi

  printf $cpu
}

# convert pod to smallest possible value (one pod) depending on unit
function convertPods()
{
  local pods_count=$1
  local pods_unit=$2

  # k = 1000 pods
  if [[ ${pods_unit} == "k" ]]; then
    pods=$(( ${pods_count} * 1000 ))
  # no unit
  elif [[ ${pods_unit} == "" ]]; then
    pods=${pods_count}
  else
    echo "UNKNOWN: unexpected pods unit (${pods_unit})."
    exit ${STATE_UNKNOWN}
  fi

  printf $pods
}

# We all need help from time to time
usage ()
{
printf "check_rancher2 v ${version} (c) 2018-2022 Claudio Kuenzler and contributers (published under GPLv2)
Usage: $0 -H Rancher2Address -U user-token -P password [-S] -t checktype [-c cluster] [-p project] [-w workload]

Options:
\t[ -H | --apihost ] Address of Rancher 2 API (e.g. rancher.example.com)
\t[ -U | --apiuser ] API username (Access Key)
\t[ -P | --apipass ] API password (Secret Key)
\t[ -S | --secure  ] Use https instead of http
\t[ -s | --selfsigned ] Allow self-signed certificates
\t[ -t | --type ] Check type (see list below for available check types)
\t[ -c | --clustername ] Cluster name (for specific cluster check)
\t[ -p | --projectname ] Project name (for specific project check, needed for workload checks)
\t[ -n | --namespacename ] Namespace name (needed for specific workload or pod checks)
\t[ -w | --workloadname ] Workload name (for specific workload check)
\t[ -o | --podname ] Pod name (for specific pod check, this makes only sense if you use static pods)
\t[ -i | --ignore ] Comma-separated list of status(es) to ignore (currently only supported in node check type)
\t[ --cpu-warn ] Exit with WARNING status if more than PERCENT of cpu capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ --cpu-crit ] Exit with CRITICAL status if more than PERCENT of cpu capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ --memory-warn ] Exit with WARNING status if more than PERCENT of mem capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ --memory-crit ] Exit with CRITICAL status if more than PERCENT of mem capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ --pods-warn ] Exit with WARNING status if more than PERCENT of pod capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ --pods-crit ] Exit with CRITICAL status if more than PERCENT of pod capacity is used (currently only supported in cluster specific node and cluster check type)
\t[ -h  | --help ] Help. I need somebody. Help. Not just anybody. Heeeeeelp!

Check Types:
\tinfo -> Informs about available clusters and projects and their API ID's. These ID's are needed for specific checks.
\tcluster -> Checks the current status of all clusters or of a specific cluster (defined with -c clusterid)
\tnode -> Checks the current status of nodes in all clusters or of nodes in a specific cluster (defined with -c clusterid)
\tproject -> Checks the current status of all projects or of a specific project (defined with -p projectid)
\tworkload -> Checks the current status of all or a specific (-w workloadname) workload within a project (-p projectid must be set!)
\tpod -> Checks the current status of all or a specific (-o podname -n namespace) pod within a project (-p projectid must be set!)
\tcron -> Checks the current status of a single (-w workloadname) cronjob within a project (-p projectid and -w workloadname must be set!)																																		  
"
exit ${STATE_UNKNOWN}
}
#########################################################################
# Check for necessary commands
for cmd in jq curl; do
 if ! `which ${cmd} 1>/dev/null`; then
   echo "UNKNOWN: ${cmd} does not exist, please check if command exists and PATH is correct"
   exit ${STATE_UNKNOWN}
 fi
done
#########################################################################
PARSED_ARGUMENTS=$(getopt -a -n check_rancher2 -o H:U:P:t:c:p:n:w:o:Ssi:h --long apihost:,apiuser:,apipass:,type:,clustername:,projectname:,namespacename:,workloadname:,podname:,secure,selfsigned,ignore:,cpu-warn:,cpu-crit:,memory-warn:,memory-crit:,pods-warn:,pods-crit: -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
  usage
fi
#########################################################################
# Get user-given variables
eval set -- "$PARSED_ARGUMENTS"
while :; do
  case "$1" in
  -H | --apihost)       apihost=${2}       ; shift 2 ;;
  -U | --apiuser)       apiuser=${2}       ; shift 2 ;;
  -P | --apipass)       apipass=${2}       ; shift 2 ;;
  -t | --type)          type=${2}          ; shift 2 ;;
  -c | --clustername)   clustername=${2}   ; shift 2 ;;
  -p | --projectname)   projectname=${2}   ; shift 2 ;;
  -n | --namespacename) namespacename=${2} ; shift 2 ;;
  -w | --workloadname)  workloadname=${2}  ; shift 2 ;;
  -o | --podname)       podname=${2}       ; shift 2 ;;
  -S | --secure)        proto=https        ; shift ;;
  -s | --selfsigned)    selfsigned="-k"    ; shift ;;
  -i | --ignore)        ignore=${2}        ; shift 2 ;;
  --cpu-warn)           cpu_warn=${2}      ; shift 2 ;;
  --cpu-crit)           cpu_crit=${2}      ; shift 2 ;;
  --memory-warn)        memory_warn=${2}   ; shift 2 ;;
  --memory-crit)        memory_crit=${2}   ; shift 2 ;;
  --pods-warn)          pods_warn=${2}     ; shift 2 ;;
  --pods-crit)          pods_crit=${2}     ; shift 2 ;;
  --)                   shift; break ;;
  -h | --help)          usage;;
  *)      echo "Unexpected option: $1 - this should not happen. Please consult --help for valid options."
	  usage;;
  esac
done
#########################################################################
# Did user obey to usage?
if [ -z $apihost ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Missing Rancher 2.x API host address"
  exit ${STATE_UNKNOWN}
fi

if [ -z $apiuser ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Missing API user"
  exit ${STATE_UNKNOWN}
fi

if [ -z $apipass ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Missing API password"
  exit ${STATE_UNKNOWN}
fi

if [ -z $type ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Missing check type"
  exit ${STATE_UNKNOWN}
fi

if [[ "$cpu_warn" -gt "$cpu_crit" ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - cpu-warn should be lower than cpu-crit"
  exit ${STATE_UNKNOWN}
fi

if [[ "$memory_warn" -gt "$memory_crit" ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - memory-warn should be lower than memory-crit"
  exit ${STATE_UNKNOWN}
fi

if [[ "$pods_warn" -gt "$pods_crit" ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - pods-warn should be lower than pods-crit"
  exit ${STATE_UNKNOWN}
fi

#########################################################################
# Base communication check
apicheck=$(curl -s ${selfsigned} -o /dev/null -w "%{http_code}" -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")

# Detect failures
if [[ $apicheck = 000 ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Invalid host address detected: ${apihost}. Use valid IP or DNS name on which the Rancher 2 API is accessible."
  exit ${STATE_UNKNOWN}
elif [[ $apicheck = 301 ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."
  exit ${STATE_UNKNOWN}
elif [[ $apicheck = 302 ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."
  exit ${STATE_UNKNOWN}
elif [[ $apicheck = 308 ]]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."
  exit ${STATE_UNKNOWN}
elif [[ $apicheck = 401 ]]; then
  echo -e "CHECK_RANCHER2 WARNING - Authentication failed"
  exit ${STATE_WARNING}
elif [[ $apicheck = 403 ]]; then
  echo -e "CHECK_RANCHER2 CRITICAL - Access to API forbidden"
  exit ${STATE_CRITICAL}
elif [[ $apicheck -gt 499 ]]; then
  echo -e "CHECK_RANCHER2 CRITICAL - API Returned HTTP $apicheck error"
  exit ${STATE_CRITICAL}
fi

#########################################################################
# Do the checks
case ${type} in 

# --- info --- #
info)
api_out_clusters=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters")
api_out_project=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
declare -a cluster_ids=( $(echo "$api_out_clusters" | jq -r '.data[].id') )
declare -a cluster_names=( $(echo "$api_out_clusters" | jq -r '.data[].name') )
declare -a project_ids=( $(echo "$api_out_project" | jq -r '.data[].id') )
declare -a project_names=( $(echo "$api_out_project" | jq -r '.data[].name') )

#echo ${cluster_ids[*]}     # Enable for debugging
#echo ${cluster_names[*]}   # Enable for debugging
#echo ${project_ids[*]}     # Enable for debugging
#echo ${project_names[*]}   # Enable for debugging

i=0
for entry in ${cluster_ids[*]}; do
  pretty_clusters[$i]="${entry} alias ${cluster_names[$i]} -"
  let i++
done

i=0
for entry in ${project_ids[*]}; do
  pretty_projects[$i]="${entry} alias ${project_names[$i]} -"
  let i++
done


echo "CHECK_RANCHER2 OK - Found ${#cluster_ids[*]} clusters: ${pretty_clusters[*]} and ${#project_ids[*]} projects: ${pretty_projects[*]}|'clusters'=${#cluster_ids[*]};;;; 'projects'=${#project_ids[*]};;;;"
exit ${STATE_OK} 
;;

# --- cluster status check --- #
cluster)
if [[ -z $clustername ]]; then

# Check status of all clusters
  api_out_clusters=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters")
  declare -a cluster_ids=( $(echo "$api_out_clusters" | jq -r '.data[].id') )
  declare -a cluster_names=( $(echo "$api_out_clusters" | jq -r '.data[].name') )
  
  e=0
  for cluster in ${cluster_ids[*]}; do
    #echo $cluster # For Debug
    clusteralias=$(echo "$api_out_clusters" | jq -r '.data[] | select(.id == "'${cluster}'")|.name')
    declare -a clusterstate=( $(echo "$api_out_clusters" | jq -r '.data[] | select(.id == "'${cluster}'") | .state') )
    declare -a component=( $(echo "$api_out_clusters" | jq -r '.data[] | select(.id == "'${cluster}'") | .componentStatuses[]?.name') )
    declare -a healthstatus=( $(echo "$api_out_clusters" | jq -r '.data[] | select(.id == "'${cluster}'") | .componentStatuses[]?.conditions[].status') )

    if [[ "${clusterstate}" != "active" ]]; then
        componenterrors[$e]="cluster ${clusteralias} is in ${clusterstate} state -"
        clustererrors[$e]="${cluster}"
    fi

    c=0
    for status in ${healthstatus[*]}; do
      if [[ ${status} != True ]]; then 
        componenterrors[$e]="${component[$c]} in cluster ${clusteralias} is not healthy -"
        clustererrors[$e]="${cluster}"
      fi
      #echo "${component[$c]} ${status}" # For Debug
      let c++
      let e++
    done
  done

  clustererrorcount=$(echo ${clustererrors[*]} | tr ' ' '\n' | sort -u | tr '\n' ' ' | wc -w)

  if [[ ${#componenterrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${componenterrors[*]}|'clusters_total'=${#cluster_ids[*]};;;; 'clusters_errors'=${clustererrorcount};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All clusters (${#cluster_ids[*]}) are healthy|'clusters_total'=${#cluster_ids[*]};;;; 'clusters_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
 
# Check status of a single cluster 
  api_out_single_cluster=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters/${clustername}")

  # Check if that given cluster name exists
  if [[ -n $(echo "$api_out_single_cluster" | grep -i "NotFound") ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."
    exit ${STATE_CRITICAL}
  fi

  clusteralias=$(echo "$api_out_single_cluster" | jq -r '.name')
  clusterstate=$(echo "$api_out_single_cluster" | jq -r '.state')
  k8sversion=$(echo "$api_out_single_cluster" | jq -r '.version.gitVersion')
  declare -a component=( $(echo "$api_out_single_cluster" | jq -r '.componentStatuses[]?.name') )
  declare -a healthstatus=( $(echo "$api_out_single_cluster" | jq -r '.componentStatuses[]?.conditions[].status') )

  # capacity
  declare -a capacity_cpu=( $(echo "$api_out_single_cluster" | jq -r '.capacity.cpu') )
  declare -a capacity_memory=( $(echo "$api_out_single_cluster" | jq -r '.capacity.memory') )
  declare -a capacity_pods=( $(echo "$api_out_single_cluster" | jq -r '.capacity.pods') )

  # requested
  declare -a requested_cpu=( $(echo "$api_out_single_cluster" | jq -r '.requested.cpu') )
  declare -a requested_memory=( $(echo "$api_out_single_cluster" | jq -r '.requested.memory') )
  declare -a requested_pods=( $(echo "$api_out_single_cluster" | jq -r '.requested.pods') )

  # split capacity_cpu
  capacity_cpu_unit=( $(echo "${capacity_cpu}" | sed 's/^[0-9]*//g') )
  capacity_cpu_count=( $(echo "${capacity_cpu}" | sed 's/[a-zA-Z]*$//g') )

  # convert capacity_cpu depending on unit
  capacity_cpu=$(convertCpu ${capacity_cpu_count} ${capacity_cpu_unit})

  # split capacity_memory
  declare -a capacity_memory_unit=( $(echo "${capacity_memory}" | sed 's/^[0-9]*//g') )
  declare -a capacity_memory_count=( $(echo "${capacity_memory}" | sed 's/[a-zA-Z]*$//g') )

  # convert capacity_memory depending on unit
  capacity_memory=$(convertMemory ${capacity_memory_count} ${capacity_memory_unit})

  # split capacity_pods
  declare -a capacity_pods_unit=( $(echo "${capacity_pods}" | sed 's/^[0-9]*//g') )
  declare -a capacity_pods_count=( $(echo "${capacity_pods}" | sed 's/[a-zA-Z]*$//g') )

  # convert capacity_pods depending on unit
  capacity_pods=$(convertPods ${capacity_pods_count} ${capacity_pods_unit})

  # split requested_cpu
  requested_cpu_unit=( $(echo "${requested_cpu}" | sed 's/^[0-9]*//g') )
  requested_cpu_count=( $(echo "${requested_cpu}" | sed 's/[a-zA-Z]*$//g') )

  # convert requested_cpu depending on unit
  requested_cpu=$(convertCpu ${requested_cpu_count} ${requested_cpu_unit})

  # split reqested_memory
  declare -a requested_memory_unit=( $(echo "${requested_memory}" | sed 's/^[0-9]*//g') )
  declare -a requested_memory_count=( $(echo "${requested_memory}" | sed 's/[a-zA-Z]*$//g') )

  # convert requested_memory depending on unit
  requested_memory=$(convertMemory ${requested_memory_count} ${requested_memory_unit})

  # split requested_pods
  declare -a requested_pods_unit=( $(echo "${requested_pods}" | sed 's/^[0-9]*//g') )
  declare -a requested_pods_count=( $(echo "${requested_pods}" | sed 's/[a-zA-Z]*$//g') )

  # convert requested_pods depending on unit
  requested_pods=$(convertPods ${requested_pods_count} ${requested_pods_unit})

  if [[ "${clusterstate}" != "active" ]]; then
      componenterrors+="cluster ${clusteralias} is in ${clusterstate} state -"
  fi
  
  for status in ${healthstatus[*]}; do
    if [[ ${status} != True ]]; then
      componenterrors+="${component[$i]} is not healthy -"
    fi
  done

  # usage
  usage_cpu=$(( 100 * $requested_cpu/$capacity_cpu ))
  usage_memory=$(( 100 * $requested_memory/$capacity_memory ))
  usage_pods=$(( 100 * $requested_pods/$capacity_pods ))

  # threshold checks
  # cpu
  if [ ! -z $cpu_warn ] || [ ! -z $cpu_crit ]; then
    if [[ "$usage_cpu" -gt "$cpu_crit" ]]; then
      resourceerrors+="CPU usage ${usage_cpu}% > threshold of ${cpu_crit}% "
    elif [[ "$usage_cpu" -gt "$cpu_warn" ]]; then
      resourceerrors+="CPU usage ${usage_cpu}% > threshold of ${cpu_warn}% "
    fi
  fi

  # memory
  if [ ! -z $memory_warn ] || [ ! -z $memory_crit ]; then
    if [[ "$usage_memory" -gt "$memory_crit" ]]; then
      resourceerrors+="MEMORY usage ${usage_memory}% > threshold of ${memory_crit}% "
    elif [[ "$usage_memory" -gt "$memory_warn" ]]; then
      resourceerrors+="MEMORY usage ${usage_memory}% > threshold of ${memory_warn}% "
    fi
  fi

  # pods
  if [ ! -z $pods_warn ] || [ ! -z $pods_crit ]; then
    if [[ "$usage_pods" -gt "$pods_crit" ]]; then
      resourceerrors+="PODS Usage ${usage_pods} > threshold of ${pods_crit} "
    elif [[ "$usage_pods" -gt "$pods_warn" ]]; then
      resourceerrors+="PODS Usage ${usage_pods} > threshold of ${pods_warn} "
    fi
  fi

  perf_output="'component_errors'=${#componenterrors[*]};;;; 'cpu'=${requested_cpu};;;;${capacity_cpu} 'memory'=${requested_memory}B;;;0;${capacity_memory} 'pods'=${requested_pods};;;;${capacity_pods} 'usage_cpu'=${usage_cpu}%;${cpu_warn};${cpu_crit};0;100 'usage_memory'=${usage_memory}%;${memory_warn};${memory_crit};0;100 'usage_pods'=${usage_pods}%;${pods_warn};${pods_crit};0;100"

  if [[ ${#componenterrors[*]} -gt 0 && ! -z ${resourceerrors} ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clusteralias has resource problems and component errors: ${resourceerrors} ${componenterrors[*]}|'cluster_healthy'=0;;;; ${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ${#componenterrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clusteralias: ${componenterrors[*]}|'cluster_healthy'=0;;;; ${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ! -z ${resourceerrors} ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clusteralias has resource problems: ${resourceerrors}|'cluster_healthy'=0;;;; ${perf_output}"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Cluster $clusteralias ($k8sversion) is healthy|'cluster_healthy'=1;;;; ${perf_output}"
    exit ${STATE_OK}
  fi

fi
;;

# --- node status check --- #
node)
if [[ -z $clustername ]]; then

# Check status of all nodes in all clusters
  api_out_nodes=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/nodes")
  declare -a node_names=( $(echo "$api_out_nodes" | jq -r '.data[].nodeName') )
  declare -a node_status=( $(echo "$api_out_nodes" | jq -r '.data[].state') )
  declare -a node_cluster_member=( $(echo "$api_out_nodes" | jq -r '.data[].clusterId') )
  declare -a node_diskpressure=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="DiskPressure").status' | awk '/True/ {print FNR}' ) )
  declare -a node_memorypressure=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="MemoryPressure").status' | awk '/True/ {print FNR}' ) )
  declare -a node_kubeletready=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="Ready").status' | awk '/False/ {print FNR}' ) )
  declare -a node_network=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="NetworkUnavailable").status' | awk '/True/ {print FNR}' ) )

  # node capacity
  declare -a node_capacity_cpu=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.cpu' ) )
  declare -a node_capacity_memory=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.memory' ) )
  declare -a node_capacity_pods=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.pods' ) )

  # node requested
  declare -a node_requested_cpu=( $(echo "$api_out_nodes" | jq -r '.data[].requested.cpu' ) )
  declare -a node_requested_memory=( $(echo "$api_out_nodes" | jq -r '.data[].requested.memory' ) )
  declare -a node_requested_pods=( $(echo "$api_out_nodes" | jq -r '.data[].requested.pods' ) )


  # Check node status (user controlled)
  i=0
  for node in ${node_names[*]}; do
    for status in ${node_status[$i]}; do
      if [[ ${status} != active ]]; then
        if [[ -n $(echo ${ignore} | grep -i ${status}) ]]; then
          nodeignored[$i]="${node} in cluster ${node_cluster_member[$i]} is ${node_status[$i]} but ignored \n"
        else
          nodeerrors[$i]="${node} in cluster ${node_cluster_member[$i]} is ${node_status[$i]} \n"
        fi
      fi
    done
  let i++
  done

  # Handle node pressure situations and other conditions (Kubernetes controlled)
  if [[ ${#node_diskpressure[*]} -gt 0 ]]; then
    for n in ${node_diskpressure[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} has Disk Pressure \n")
    done
  fi

  if [[ ${#node_memorypressure[*]} -gt 0 ]]; then
    for n in ${node_memorypressure[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} has Memory Pressure \n")
    done
  fi

  if [[ ${#node_kubeletready[*]} -gt 0 ]]; then
    for n in ${node_kubeletready[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("Kubelet on node ${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} is not ready \n")
    done
  fi

  if [[ ${#node_network[*]} -gt 0 ]]; then
    for n in ${node_network[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("Network on node ${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} is unavailable \n")
    done
  fi

  # calculate total capacities
  nodes_capacity_cpu_total=0
  for capacity_cpu in ${node_capacity_cpu[@]}; do
    # split capacity_cpu
    capacity_cpu_unit=( $(echo "${capacity_cpu}" | sed 's/^[0-9]*//g') )
    capacity_cpu_count=( $(echo "${capacity_cpu}" | sed 's/[a-zA-Z]*$//g') )

    # convert capacity_cpu depending on unit
    capacity_cpu=$(convertCpu ${capacity_cpu_count} ${capacity_cpu_unit})

    let nodes_capacity_cpu_total+=$capacity_cpu
  done

  nodes_capacity_memory_total=0
  for capacity_memory in ${node_capacity_memory[@]}; do
    # split capacity_memory
    capacity_memory_unit=( $(echo "${capacity_memory}" | sed 's/^[0-9]*//g') )
    capacity_memory_count=( $(echo "${capacity_memory}" | sed 's/[a-zA-Z]*$//g') )

    # convert capacity_memory depending on unit
    capacity_memory=$(convertMemory ${capacity_memory_count} ${capacity_memory_unit})

    let nodes_capacity_memory_total+=$capacity_memory
  done

  nodes_capacity_pods_total=0
  for capacity_pods in ${node_capacity_pods[@]}; do
    # split capacity_pods
    capacity_pods_unit=( $(echo "${capacity_pods}" | sed 's/^[0-9]*//g') )
    capacity_pods_count=( $(echo "${capacity_pods}" | sed 's/[a-zA-Z]*$//g') )

    # convert capacity_pods depending on unit
    capacity_pods=$(convertPods ${capacity_pods_count} ${capacity_pods_unit})
     
    let nodes_capacity_pods_total+=$capacity_pods
  done

  # calculate total requested
  nodes_requested_cpu_total=0
  for requested_cpu in ${node_requested_cpu[@]}; do
    # split requested_cpu
    requested_cpu_unit=( $(echo "${requested_cpu}" | sed 's/^[0-9]*//g') )
    requested_cpu_count=( $(echo "${requested_cpu}" | sed 's/[a-zA-Z]*$//g') )

    # convert requested_cpu depending on unit
    requested_cpu=$(convertCpu ${requested_cpu_count} ${requested_cpu_unit})

    let nodes_requested_cpu_total+=$requested_cpu
  done

  nodes_requested_memory_total=0
  for requested_memory in ${node_requested_memory[@]}; do
    # split requested_memory
    requested_memory_unit=( $(echo "${requested_memory}" | sed 's/^[0-9]*//g') )
    requested_memory_count=( $(echo "${requested_memory}" | sed 's/[a-zA-Z]*$//g') )

    # convert requested_memory depending on unit
    requested_memory=$(convertMemory ${requested_memory_count} ${requested_memory_unit})

    let nodes_requested_memory_total+=$requested_memory
  done

  nodes_requested_pods_total=0
  for requested_pods in ${node_requested_pods[@]}; do
    # split requested_pods
    requested_pods_unit=( $(echo "${requested_pods}" | sed 's/^[0-9]*//g') )
    requested_pods_count=( $(echo "${requested_pods}" | sed 's/[a-zA-Z]*$//g') )

    # convert requested_pods depending on unit
    requested_pods=$(convertPods ${requested_pods_count} ${requested_pods_unit})

    let nodes_requested_pods_total+=$requested_pods
  done

  perf_output="'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;; 'node_ignored'=${#nodeignored[*]};;;; 'nodes_cpu_total'=${nodes_requested_cpu_total};;;0;${nodes_capacity_cpu_total} 'nodes_memory_total'=${nodes_requested_memory_total}B;;;0;${nodes_capacity_memory_total} 'nodes_pods_total'=${nodes_requested_pods_total};;;0;${nodes_capacity_pods_total}"
  
  if [[ ${#nodeerrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${#nodeerrors[*]} abnormal node states: ${nodeerrors[*]}${nodeignored[*]}|${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ${#nodeignored[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 OK - All nodes OK - Info: ${#nodeignored[*]} node errors ignored: ${nodeerrors[*]}${nodeignored[*]}|${perf_output}"
    exit ${STATE_OK}
  else
    echo "CHECK_RANCHER2 OK - All ${#node_names[*]} nodes are active|${perf_output}"
    exit ${STATE_OK}
  fi

else

# Check status of all nodes in a specific cluster
  api_out_nodes=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/nodes/?clusterId=${clustername}")
  declare -a node_diskpressure=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="DiskPressure").status' | awk '/True/ {print FNR}' ) )
  declare -a node_memorypressure=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="MemoryPressure").status' | awk '/True/ {print FNR}' ) )
  declare -a node_kubeletready=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="Ready").status' | awk '/False/ {print FNR}' ) )
  declare -a node_network=( $(echo "$api_out_nodes" | jq -r '.data[].conditions[] | select(.type=="NetworkUnavailable").status' | awk '/True/ {print FNR}' ) )

  # node capacity
  declare -a node_capacity_cpu=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.cpu' ) )
  declare -a node_capacity_memory=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.memory' ) )
  declare -a node_capacity_pods=( $(echo "$api_out_nodes" | jq -r '.data[].capacity.pods' ) )

  # node requested
  declare -a node_requested_cpu=( $(echo "$api_out_nodes" | jq -r '.data[].requested.cpu' ) )
  declare -a node_requested_memory=( $(echo "$api_out_nodes" | jq -r '.data[].requested.memory' ) )
  declare -a node_requested_pods=( $(echo "$api_out_nodes" | jq -r '.data[].requested.pods' ) )

  # Check if that given cluster name exists
  if [[ -n $(echo "$api_out_nodes" | grep -i "NotFound") ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  declare -a node_names=( $(echo "$api_out_nodes" | jq -r '.data[].nodeName') )
  declare -a node_status=( $(echo "$api_out_nodes" | jq -r '.data[].state') )

  # Check node status (user controlled)
  i=0
  for node in ${node_names[*]}; do
    for status in ${node_status[$i]}; do
      if [[ ${status} != active ]]; then
        if [[ -n $(echo ${ignore} | grep -i ${status}) ]]; then
          nodeignored[$i]="${node} in cluster ${node_cluster_member[$i]} is ${node_status[$i]} but ignored \n"
        else
          nodeerrors[$i]="${node} in cluster ${clustername} is ${node_status[$i]} \n"
        fi
      fi
    done
  let i++
  done
    
  # check capacities per node 
  i=0
  for node in ${node_names[*]}; do
    # split node_capacity_cpu
    node_capacity_cpu_unit=( $(echo "${node_capacity_cpu[$i]}" | sed 's/^[0-9]*//g') )
    node_capacity_cpu_count=( $(echo "${node_capacity_cpu[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_capacity_cpu depding on unit
    capacity_cpu=$(convertCpu ${node_capacity_cpu_count} ${node_capacity_cpu_unit})

    # split node_capacity_memory
    node_capacity_memory_unit=( $(echo "${node_capacity_memory[$i]}" | sed 's/^[0-9]*//g') )
    node_capacity_memory_count=( $(echo "${node_capacity_memory[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_capacity_memory depnding on unit
    capacity_memory=$(convertMemory ${node_capacity_memory_count} ${node_capacity_memory_unit})

    # split node_capacity_pods
    node_capacity_pods_unit=( $(echo "${node_capacity_pods[$i]}" | sed 's/^[0-9]*//g') )
    node_capacity_pods_count=( $(echo "${node_capacity_pods[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_capacity_pods depending on unit
    capacity_pods=$(convertPods ${node_capacity_pods_count} ${node_capacity_pods_unit})

    # split node_requested_cpu
    node_requested_cpu_unit=( $(echo "${node_requested_cpu[$i]}" | sed 's/^[0-9]*//g') )
    node_requested_cpu_count=( $(echo "${node_requested_cpu[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_requested_cpu depending on unit 
    requested_cpu=$(convertCpu ${node_requested_cpu_count} ${node_requested_cpu_unit})

    # split node_requested_memory
    node_requested_memory_unit=( $(echo "${node_requested_memory[$i]}" | sed 's/^[0-9]*//g') )
    node_requested_memory_count=( $(echo "${node_requested_memory[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_requested_memory depending on unit
    requested_memory=$(convertMemory ${node_requested_memory_count} ${node_requested_memory_unit})

    # split node_requested_pods
    node_requested_pods_unit=( $(echo "${node_requested_pods[$i]}" | sed 's/^[0-9]*//g') )
    node_requested_pods_count=( $(echo "${node_requested_pods[$i]}" | sed 's/[a-zA-Z]*$//g') )

    # convert node_requested_pods depending on unit
    requested_pods=$(convertPods ${node_requested_pods_count} ${node_requested_pods_unit})

    # usage
    usage_cpu=$(( 100 * $requested_cpu/$capacity_cpu ))
    usage_memory=$(( 100 * $requested_memory/$capacity_memory ))
    usage_pods=$(( 100 * $requested_pods/$capacity_pods ))

  node_perf_output+="${node}_cpu=${requested_cpu};;;0;${capacity_cpu} ${node}_memory=${requested_memory}B;;;0;${capacity_memory} ${node}_pods=${requested_pods};;;0;${capacity_pods} "

  # threshold checks
  # cpu
  if [ ! -z $cpu_warn ] || [ ! -z $cpu_crit ]; then
    if [[ "$usage_cpu" -gt "$cpu_crit" ]]; then
      resourceerrors+="${node} - CPU usage ${usage_cpu} higher than crit threshold of ${cpu_crit} \n"
    elif [[ "$usage_cpu" -gt "$cpu_warn" ]]; then
      resourceerrors+="${node} - CPU usage ${usage_cpu} higher than warn threshold of ${cpu_warn} \n"
    fi
  fi

  # memory
  if [ ! -z $memory_warn ] || [ ! -z $memory_crit ]; then
    if [[ "$usage_memory" -gt "$memory_crit" ]]; then
      resourceerrors+="${node} - MEMORY usage ${usage_memory} higher than crit threshold of ${memory_crit} \n"
    elif [[ "$usage_memory" -gt "$memory_warn" ]]; then
      resourceerrors+="${node} - MEMORY usage ${usage_memory} higher than warn threshold of ${memory_warn} \n"
    fi
  fi

  # pods
  if [ ! -z $pods_warn ] || [ ! -z $pods_crit ]; then
    if [[ "$usage_pods" -gt "$pods_crit" ]]; then
      resourceerrors+="${node} - PODS Usage ${usage_pods} higher than crit threshold of ${pods_crit} \n"
    elif [[ "$usage_pods" -gt "$pods_warn" ]]; then
      resourceerrors+="${node} - PODS Usage ${usage_pods} higher than warn threshold of ${pods_warn} \n"
    fi
  fi

  let i++
  done

  # Handle node pressure situations and other conditions (Kubernetes controlled)
  if [[ ${#node_diskpressure[*]} -gt 0 ]]; then
    for n in ${node_diskpressure[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} has Disk Pressure \n")
    done
  fi

  if [[ ${#node_memorypressure[*]} -gt 0 ]]; then
    for n in ${node_memorypressure[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} has Memory Pressure \n")
    done
  fi

  if [[ ${#node_kubeletready[*]} -gt 0 ]]; then
    for n in ${node_kubeletready[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("Kubelet on node ${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} is not ready \n")
    done
  fi

  if [[ ${#node_network[*]} -gt 0 ]]; then
    for n in ${node_network[*]}; do
      hostid=$(( $n - 1 ))
      nodeerrors+=("Network on node ${node_names[$hostid]} in cluster ${node_cluster_member[$hostid]} is unavailable \n")
    done
  fi

  # calculate total capacities
  nodes_capacity_cpu_total=0
  for capacity_cpu in ${node_capacity_cpu[@]}; do
    # split capacity_cpu
    capacity_cpu_unit=( $(echo "${capacity_cpu}" | sed 's/^[0-9]*//g') )
    capacity_cpu_count=( $(echo "${capacity_cpu}" | sed 's/[a-zA-Z]*$//g') )
    
    # convert capacity_cpu depending on unit
    capacity_cpu=$(convertCpu ${capacity_cpu_count} ${capacity_cpu_unit})
    
    let nodes_capacity_cpu_total+=$capacity_cpu
  done

  nodes_capacity_memory_total=0
  for capacity_memory in ${node_capacity_memory[@]}; do
    # split capacity_memory
    capacity_memory_unit=( $(echo "${capacity_memory}" | sed 's/^[0-9]*//g') )
    capacity_memory_count=( $(echo "${capacity_memory}" | sed 's/[a-zA-Z]*$//g') )
    
    # convert capacity_memory depending on unit
    capacity_memory=$(convertMemory ${capacity_memory_count} ${capacity_memory_unit})
    
    let nodes_capacity_memory_total+=$capacity_memory
  done

  nodes_capacity_pods_total=0
  for capacity_pods in ${node_capacity_pods[@]}; do
    # split capacity_pods
    capacity_pods_unit=( $(echo "${capacity_pods}" | sed 's/^[0-9]*//g') )
    capacity_pods_count=( $(echo "${capacity_pods}" | sed 's/[a-zA-Z]*$//g') )
    
    # convert capacity_pods depending on unit
    capacity_pods=$(convertPods ${capacity_pods_count} ${capacity_pods_unit})
    
    let nodes_capacity_pods_total+=$capacity_pods
  done

  # calculate total requested
  nodes_requested_cpu_total=0
  for requested_cpu in ${node_requested_cpu[@]}; do
    # split requested_cpu
    requested_cpu_unit=( $(echo "${requested_cpu}" | sed 's/^[0-9]*//g') )
    requested_cpu_count=( $(echo "${requested_cpu}" | sed 's/[a-zA-Z]*$//g') )
    
    # convert requested_cpu depending on unit
    requested_cpu=$(convertCpu ${requested_cpu_count} ${requested_cpu_unit})
    
    let nodes_requested_cpu_total+=$requested_cpu
  done

  nodes_requested_memory_total=0
  for requested_memory in ${node_requested_memory[@]}; do
    # split requested_memory
    requested_memory_unit=( $(echo "${requested_memory}" | sed 's/^[0-9]*//g') )
    requested_memory_count=( $(echo "${requested_memory}" | sed 's/[a-zA-Z]*$//g') )
    
    # convert requested_memory depending on unit
    requested_memory=$(convertMemory ${requested_memory_count} ${requested_memory_unit})

    let nodes_requested_memory_total+=$requested_memory
  done

  nodes_requested_pods_total=0
  for requested_pods in ${node_requested_pods[@]}; do
    # split requested_pods
    requested_pods_unit=( $(echo "${requested_pods}" | sed 's/^[0-9]*//g') )
    requested_pods_count=( $(echo "${requested_pods}" | sed 's/[a-zA-Z]*$//g') )

    # convert requested_pods depending on unit
    requested_pods=$(convertPods ${requested_pods_count} ${requested_pods_unit})

    let nodes_requested_pods_total+=$requested_pods
  done

  perf_output="'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;; 'node_ignored'=${#nodeignored[*]};;;; 'nodes_cpu_total'=${nodes_requested_cpu_total};;;0;${nodes_capacity_cpu_total} 'nodes_memory_total'=${nodes_requested_memory_total}B;;;0;${nodes_capacity_memory_total} 'nodes_pods_total'=${nodes_requested_pods_total};;;0;${nodes_capacity_pods_total} ${node_perf_output}"

  if [[ ${#nodeerrors[*]} -gt 0 && ! -z ${resourceerrors} ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${#nodeerrors[*]} abnormal node states and resource problems: ${nodeerrors[*]}${resourceerrors}${nodeignored[*]}|${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ${#nodeerrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${#nodeerrors[*]} abnormal node states: ${nodeerrors[*]}${resourceerrors}${nodeignored[*]}|${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ! -z ${resourceerrors} ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Nodes with resource problems: ${nodeerrors[*]}${resourceerrors}${nodeignored[*]}|${perf_output}"
    exit ${STATE_CRITICAL}
  elif [[ ${#nodeignored[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 OK - All nodes OK - Info: ${nodeignored[*]}|${perf_output}"
    exit ${STATE_OK}
  else
    echo "CHECK_RANCHER2 OK - All ${#node_names[*]} nodes are active|${perf_output}"
    exit ${STATE_OK}
  fi

fi
;;


# --- project status check --- #
project)
if [[ -z $projectname ]]; then

# Check status of all projects
  api_out_project=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
  declare -a project_ids=( $(echo "$api_out_project" | jq -r '.data[].id') )
  declare -a project_names=( $(echo "$api_out_project" | jq -r '.data[].name') )
  declare -a cluster_ids=( $(echo "$api_out_project" | jq -r '.data[].clusterId') )
  declare -a healthstatus=( $(echo "$api_out_project" | jq -r '.data[].state') )
  
  i=0
  for project in ${project_ids[*]}; do
    if [[ ${healthstatus[$i]} != "active" ]]; then
      projecterrors[$i]="${project} in cluster ${cluster_ids[$i]} is not healthy (state = ${healthstatus[$i]})"
    fi
    let i++
  done

  if [[ ${#projecterrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${projecterrors[*]}|'projects_total'=${#project_ids[*]};;;; 'project_errors'=${#projecterrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All projects (${#project_ids[*]}) are healthy|'projects_total'=${#project_ids[*]};;;; 'project_errors'=${#projecterrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
 
# Check status of a single project
  api_out_single_project=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}")

  # Check if that given project name exists
  if [[ -n $(echo "$api_out_single_project" | grep -i "NotFound") ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Project $projectname not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_project" | jq -r '.state')
  
  if [[ ${healthstatus} != active ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Project $projectname is not active|'project_active'=0;;;; 'project_error'=1;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Project $projectname is active|'project_active'=1;;;; 'project_error'=0;;;;"
    exit ${STATE_OK}
  fi
  
fi
;;

# --- workload status check (requires project)--- #
service)
  echo -e "CHECK_RANCHER2 UNKNOWN - In Rancher 2 services are called workloads. Use -t workload."
  exit ${STATE_UNKNOWN}
;;

workload)
if [ -z $projectname ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - To check workloads you must also define the project (-p). This will check all workloads within the given project. To check a specific workload, define it with -w."
  exit ${STATE_UNKNOWN}
fi

if [[ -z $workloadname ]]; then

# Check status of all workloads within a project (project must be given)
  api_out_workloads=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads")

  if [[ -n $(echo "$api_out_workloads" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."
    exit ${STATE_CRITICAL}
  fi

  declare -a workload_names=( $(echo "$api_out_workloads" | jq -r '.data[].name') )
  declare -a healthstatus=( $(echo "$api_out_workloads" | jq -r '.data[].state') )
  declare -a pausedstatus=( $(echo "$api_out_workloads" | jq -r '.data[].paused') )

  # We rather WARN than silently return OK for zero workloads
  if [[ ${#workload_names} -eq 0 ]]; then
    echo "CHECK_RANCHER2 WARNING - No workloads found in project ${projectname}."
    exit ${STATE_WARNING}
  fi
 
  i=0
  for workload in ${workload_names[*]}; do
    for status in ${healthstatus[$i]}; do
      if [[ ${status} = updating ]]; then
        if [[ -n $(echo ${ignore} | grep -i ${status}) ]]; then
          workloadignored[$i]="Workload ${workload} is ${status} but ignored -"
        else
          workloadwarnings[$i]="Workload ${workload} is ${status} -"
        fi
      elif [[ ${status} != active ]]; then
        if [[ -n $(echo ${ignore} | grep -i ${status}) ]]; then
          workloadignored[$i]="Workload ${workload} is ${status} but ignored -"
        else
          workloaderrors[$i]="Workload ${workload} is ${status} -"
        fi
      fi
    done
    for paused in ${pausedstatus[$i]}; do
      if [[ ${paused} = true ]]; then
        workloadpaused[$i]="${workload} "
      fi
    done
    let i++
  done

  if [[ ${#workloadignored[*]} -gt 0 ]]; then
    ignoreoutput="- ${workloadignored[*]}"
  fi

  if [[ ${#workloaderrors[*]} -gt 0 ]]; then
    echo  "CHECK_RANCHER2 CRITICAL - ${#workloaderrors[*]} workload(s) in error state: ${workloaderrors[*]} ${ignoreoutput}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;; 'workloads_ignored'=${#workloadignored[*]};;;;"
    exit ${STATE_CRITICAL}
  elif [[ ${#workloadwarnings[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 WARNING - ${#workloadwarnings[*]} workload(s) in warning state: ${workloadwarnings[*]} ${ignoreoutput}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;; 'workloads_ignored'=${#workloadignored[*]};;;;"
    exit ${STATE_WARNING}
  else
    if [[ ${#workloadpaused[*]} -gt 0 ]]; then
      echo "CHECK_RANCHER2 OK - All workloads (${#workload_names[*]}) in project ${projectname} are healthy/active ( Note: ${#workloadpaused[*]} workloads currently paused: ${workloadpaused[*]}) ${ignoreoutput}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;; 'workloads_ignored'=${#workloadignored[*]};;;;"
    else
      echo "CHECK_RANCHER2 OK - All workloads (${#workload_names[*]}) in project ${projectname} are healthy/active ${ignoreoutput}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;; 'workloads_ignored'=${#workloadignored[*]};;;;"
    fi
    exit ${STATE_OK}
  fi

else
 
# Check status of a single workload
  if [[ -n $namespacename && $namespacename != "" ]]; then
    nsappend="&namespaceId=$namespacename"
    nsoutputappend="in namespace $namespacename "
  fi

  api_out_single_workload=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads/?name=${workloadname}${nsappend}")

  if [[ -n $(echo "$api_out_single_workload" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  # Check if that given project name exists
  if [[ -z $(echo "$api_out_single_workload" | grep -i "containers") ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname ${nsoutputappend}not found."; exit ${STATE_CRITICAL}
  fi

  # Check if there are multiple workloads with the same name
  workloadcount=$(echo "$api_out_single_workload" | jq -r '.data[].id' | wc -l)
  if [[ $workloadcount -gt 1 ]]; then
    echo "CHECK_RANCHER2 UNKNOWN - Identical workload names detected in multiple namespaces. To check a specific workload you must also define the namespace (-n)."
    exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_workload" | jq -r '.data[].state')
  
  if [[ ${healthstatus} = updating ]]; then
    if [[ -n $(echo ${ignore} | grep -i ${healthstatus}) ]]; then
      echo "CHECK_RANCHER2 OK - Workload $workloadname ${nsoutputappend}is ${healthstatus} but ignored|'workload_active'=0;;;; 'workload_error'=0;;;; 'workload_warning'=1;;;; 'workload_ignored'=1;;;;"
      exit ${STATE_WARNING}
    else
      echo "CHECK_RANCHER2 WARNING - Workload $workloadname ${nsoutputappend}is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=0;;;; 'workload_warning'=1;;;; 'workload_ignored'=0;;;;"
      exit ${STATE_WARNING}
    fi
  elif [[ ${healthstatus} != active ]]; then
    if [[ -n $(echo ${ignore} | grep -i ${healthstatus}) ]]; then
      echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname ${nsoutputappend}is ${healthstatus} but ignored|'workload_active'=0;;;; 'workload_error'=1;;;; 'workload_warning'=0;;;; 'workload_ignored'=1;;;;"
      exit ${STATE_CRITICAL}
    else
      echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname ${nsoutputappend}is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=1;;;; 'workload_warning'=0;;;; 'workload_ignored'=0;;;;"
      exit ${STATE_CRITICAL}
    fi
  else
    echo "CHECK_RANCHER2 OK - Workload $workloadname ${nsoutputappend}is active|'workload_active'=1;;;; 'workload_error'=0;;;; 'workload_warning'=0;;;; 'workload_ignored'=0;;;;"
    exit ${STATE_OK}
  fi
  
fi
;;

# --- pod status check (requires project) --- #
pod)
if [ -z $projectname ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - To check pods you must also define the project (-p). This will check all pods within the given project. To check a specific pod, define it with -o podname and -n namespace."
  exit ${STATE_UNKNOWN}
fi

if [[ -z $podname ]]; then

# Check status of all pods within a project (project must be given)
  if [[ -n $namespacename && $namespacename != "" ]]; then
    nsappend="?namespaceId=$namespacename"
    outputappend="and namespace $namespacename "
  fi

  api_out_pods=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/pods${nsappend}")

  if [[ -n $(echo "$api_out_pods" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."
    exit ${STATE_CRITICAL}
  fi

  declare -a pod_names=( $(echo "$api_out_pods" | jq -r '.data[].name') )
  declare -a healthstatus=( $(echo "$api_out_pods" | jq -r '.data[].state') )

  # We rather WARN than silently return OK for zero pods
  if [[ ${#pod_names} -eq 0 ]]; then
    echo "CHECK_RANCHER2 WARNING - No pods found in project ${projectname}."
    exit ${STATE_WARNING}
  fi

  i=0
  for pod in ${pod_names[*]}; do
    for status in ${healthstatus[$i]}; do
      if [[ ${status} != running && ${status} != succeeded ]]; then
        poderrors[$i]="Pod ${pod} is ${status}\n"
      fi
    done
    let i++
  done

  if [[ ${#poderrors[*]} -gt 0 ]]; then
    echo "CHECK_RANCHER2 CRITICAL - ${#poderrors[*]} pod(s) in project ${projectname} ${outputappend}in abnormal state: ${poderrors[*]}|'pods_total'=${#pod_names[*]};;;; 'pods_errors'=${#poderrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All pods (${#pod_names[*]}) in project ${projectname} ${outputappend}are running|'pods_total'=${#pod_names[*]};;;; 'pods_errors'=${#poderrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
# Check status of a single pod (requires project and namespace)
# Note: This only makes sense when you create static pods!
  if [ -z $namespacename ]; then
    echo -e "CHECK_RANCHER2 UNKNOWN - To check a single pod you must also define the namespace (-n)."
    exit ${STATE_UNKNOWN}
  fi
  
  api_out_single_pod=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/pods/${namespacename}:${podname}")

  if [[ -n $(echo "$api_out_single_pod" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  # Check if that given project name exists
  if [[ -z $(echo "$api_out_single_pod" | grep -i "containers") ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Pod $podname not found. Verify project (-p) and pod (-o) names."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_pod" | jq -r '.state')

  if [[ ${healthstatus} != running ]]; then
    echo "CHECK_RANCHER2 CRITICAL - Pod $podname is ${healthstatus}|'pod_active'=0;;;; 'pod_error'=1;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Pod $podname is running|'pod_active'=1;;;; 'pod_error'=0;;;;"
    exit ${STATE_OK}
  fi

fi
;;

# --- cronjob status check (requires project, namespace and workload name)--- #

cron)
if [ -z $projectname ] || [ -z $workloadname ] || [ -z $namespacename ]; then
  echo -e "CHECK_RANCHER2 UNKNOWN - To check a cronjob you must define the project (-p), workloadname (-w) and the namespace (-n)."
  exit ${STATE_UNKNOWN}
fi

if [[ -n $namespacename && $namespacename != "" ]]; then
  nsappend="&namespaceId=$namespacename"
  nsoutputappend="in namespace $namespacename "
fi

api_out_single_cronjob=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads/cronjob:${namespacename}:${workloadname}")

# Check if cluster is available
if [[ -n $(echo "$api_out_single_cronjob" | grep -i "ClusterUnavailable") ]]; then
  clustername=$(echo ${projectname} | awk -F':' '{print $1}')
  echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names." 
  exit ${STATE_CRITICAL}
fi

# Check if that given project name exists
if [[ -z $(echo "$api_out_single_cronjob" | grep -i "containers") ]]; then
  echo "CHECK_RANCHER2 CRITICAL - Cronjob $workloadname ${nsoutputappend}not found." 
  exit ${STATE_CRITICAL}
fi

# Path to cron schedule converter
cronconverter=./convert_cron_schedule.py

# Check healthstatus of cronjob
healthstatus=$(echo "$api_out_single_cronjob" | jq -r '.state')
suspended=$(echo "$api_out_single_cronjob" | jq -r '.cronJobConfig.suspend')

# Check if cronjob is active and runs in defined schedule
if test -f "$cronconverter"; then

  if [[ ${healthstatus} = active ]]; then
    cronschedule=$(echo "$api_out_single_cronjob" | jq -r '.cronJobConfig.schedule')
    crondiff=$(python3 $cronconverter "$cronschedule" difftimestamp)
    currenttime=$(date +%s%N | cut -b1-13)
    lastruntime=$(echo "$api_out_single_cronjob" | jq -r '.cronJobStatus.lastScheduleTimeTS')
    currentdiff=$((currenttime-lastruntime))

    if [[ ${suspended} = true ]]; then
      echo "CHECK_RANCHER2 WARNING - Cronjob $workloadname ${nsoutputappend}is suspended.|'workload_active'=0;;;; 'workload_error'=0;;;; 'workload_warning'=1;;;;"
      exit ${STATE_WARNING}
    
    elif [[ $currentdiff -gt $crondiff ]]; then
      echo "CHECK_RANCHER2 CRITICAL - Cronjob $workloadname ${nsoutputappend}is not running in schedule time."
      exit ${STATE_CRITICAL}
    else
      echo "CHECK_RANCHER2 OK - Cronjob $workloadname ${nsoutputappend}is running properly."
      exit ${STATE_OK}
    fi

  elif [[ ${healthstatus} = updating ]]; then
    echo "CHECK_RANCHER2 WARNING - Cronjob $workloadname ${nsoutputappend}is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=0;;;; 'workload_warning'=1;;;;"
    exit ${STATE_WARNING}

  else
    echo "CHECK_RANCHER2 CRITICAL - Cronjob $workloadname ${nsoutputappend}is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=1;;;; 'workload_warning'=0;;;;"
    exit ${STATE_CRITICAL}
  fi

else 
  echo "CHECK_RANCHER2 UNKNOWN - Resource not found: convert_cron_schedule.py"
  exit ${STATE_UNKNOWN}
fi
;;


esac
echo "UNKNOWN: should never reach this part"
exit ${STATE_UNKNOWN}
