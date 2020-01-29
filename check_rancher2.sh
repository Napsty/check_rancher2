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
# Copyright 2018-2020 Claudio Kuenzler                                                   #
# Copyright 2020 Matthias Kneer                                                          #
#											 #
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
##########################################################################################
# (Pre-)Define some fixed variables
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH # Set path
proto=http		# Protocol to use, default is http, can be overwritten with -S parameter
version=1.2.2

# Check for necessary commands
for cmd in jshon curl [
do
 if ! `which ${cmd} 1>/dev/null`
 then
 echo "UNKNOWN: ${cmd} does not exist, please check if command exists and PATH is correct"
 exit ${STATE_UNKNOWN}
 fi
done
#########################################################################
# We all need help from time to time
help="check_rancher2 v ${version} (c) 2018-2020 Claudio Kuenzler and contributers (published under GPLv2)\n
Usage: $0 -H Rancher2Address -U user-token -P password [-S] -t checktype [-c cluster] [-p project] [-w workload]\n
\nOptions:\n
\t-H Address of Rancher 2 API (e.g. rancher.example.com)\n
\t-U API username (Access Key)\n
\t-P API password (Secret Key)\n
\t-S Use https instead of http\n
\t-s Allow self-signed certificates\n
\t-t Check type (see list below for available check types)\n
\t-c Cluster name (for specific cluster check)\n
\t-p Project name (for specific project check, needed for workload checks)\n
\t-n Namespace name (needed for specific pod checks)\n
\t-w Workload name (for specific workload check)\n
\t-o Pod name (for specific pod check, this makes only sense if you use static pods)\n
\t-h Help. I need somebody. Help. Not just anybody. Heeeeeelp!\n
\nCheck Types:\n
\tinfo -> Informs about available clusters and projects and their API ID's. These ID's are needed for specific checks.\n
\tcluster -> Checks the current status of all clusters or of a specific cluster (defined with -c clusterid)\n
\tnode -> Checks the current status of all nodes or of nodes in a specific cluster (defined with -c clusterid)\n
\tproject -> Checks the current status of all projects or of a specific project (defined with -p projectid)\n
\tworkload -> Checks the current status of all or a specific (-w workloadname) workload within a project (-p projectid must be set!)\n
\tpod -> Checks the current status of all or a specific (-o podname -n namespace) pod within a project (-p projectid must be set!)\n
\n"

if [ "${1}" = "--help" -o "${#}" = "0" ];
       then echo -e ${help}; exit 1;
fi
#########################################################################
# Get user-given variables
while getopts "H:U:P:t:c:p:n:w:o:Ssh" Input;
do
  case ${Input} in
  H)      apihost=${OPTARG};;
  U)      apiuser=${OPTARG};;
  P)      apipass=${OPTARG};;
  t)      type=${OPTARG};;
  c)      clustername=${OPTARG};;
  p)      projectname=${OPTARG};;
  n)      namespacename=${OPTARG};;
  w)      workloadname=${OPTARG};;
  o)      podname=${OPTARG};;
  S)      proto=https;;
  s)      selfsigned="-k";;
  h)      echo -e ${help}; exit ${STATE_UNKNOWN};;
  *)      echo -e ${help}; exit ${STATE_UNKNOWN};;
  esac
done
#########################################################################
# Did user obey to usage?
if [ -z $apihost ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing Rancher 2.x API host address"; exit ${STATE_UNKNOWN}; fi
if [ -z $apiuser ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing API user"; exit ${STATE_UNKNOWN}; fi
if [ -z $apipass ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing API password"; exit ${STATE_UNKNOWN}; fi
if [ -z $type ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing check type"; exit ${STATE_UNKNOWN}; fi
#########################################################################
# Base communication check
apicheck=$(curl -s ${selfsigned} -o /dev/null -w "%{http_code}" -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")

# Detect failures
if [[ $apicheck = 000 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Invalid host address detected: ${apihost}. Use valid IP or DNS name on which the Rancher 2 API is accessible."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 301 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 302 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 308 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 401 ]]
then echo -e "CHECK_RANCHER2 WARNING - Authentication failed"; exit ${STATE_WARNING}
elif [[ $apicheck -gt 499 ]]
then echo -e "CHECK_RANCHER2 CRITICAL - API Returned HTTP $apicheck error"; exit ${STATE_CRITICAL}
fi
#########################################################################
# Do the checks
case ${type} in 

# --- info --- #
info)
api_out_clusters=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters")
api_out_project=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
declare -a cluster_ids=( $(echo "$api_out_clusters" | jshon -e data -a -e id) )
declare -a cluster_names=( $(echo "$api_out_clusters" | jshon -e data -a -e name) )
declare -a project_ids=( $(echo "$api_out_project" | jshon -e data -a -e id) )
declare -a project_names=( $(echo "$api_out_project" | jshon -e data -a -e name) )

#echo ${cluster_ids[*]}     # Enable for debugging
#echo ${cluster_names[*]}   # Enable for debugging
#echo ${project_ids[*]}     # Enable for debugging
#echo ${project_names[*]}   # Enable for debugging

i=0
for entry in ${cluster_ids[*]}
do
  pretty_clusters[$i]="${entry} alias ${cluster_names[$i]} -"
  let i++
done

i=0
for entry in ${project_ids[*]}
do
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
  declare -a cluster_ids=( $(echo "$api_out_clusters" | jshon -e data -a -e id) )
  declare -a cluster_names=( $(echo "$api_out_clusters" | jshon -e data -a -e name) )
  declare -a healthstatus=( $(echo "$api_out_clusters" | jshon -e data -a -e componentStatuses -a -e conditions -a -e status -u) )
  declare -a component=( $(echo "$api_out_clusters" | jshon -e data -a -e componentStatuses -a -e name -u) )
  
  for cluster in ${cluster_ids[*]}
  do
    i=0
    for status in ${healthstatus[*]}
    do 
      if [[ ${status} != True ]]; then 
        componenterrors[$i]="${component[$i]} in cluster ${cluster} is not healthy -"
      fi
    done
    let i++
  done

  if [[ ${#componenterrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - ${componenterrors[*]}|'clusters_total'=${#cluster_ids[*]};;;; 'clusters_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All clusters (${#cluster_ids[*]}) are healthy|'clusters_total'=${#cluster_ids[*]};;;; 'clusters_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
 
# Check status of a single cluster 
  api_out_single_cluster=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters/${clustername}")

  # Check if that given cluster name exists
  if [[ -n $(echo "$api_out_single_cluster" | grep -i "error") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  declare -a component=( $(echo "$api_out_single_cluster" | jshon -e componentStatuses -a -e name -u) )
  declare -a healthstatus=( $(echo "$api_out_single_cluster" | jshon -e componentStatuses -a -e conditions -a -e status -u) )
  
  i=0
  for status in ${healthstatus[*]}
  do 
    if [[ ${status} != True ]]; then 
      componenterrors[$i]="${component[$i]} is not healthy -"
    fi
    let i++
  done
  
  if [[ ${#componenterrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername: ${componenterrors[*]}|'cluster_healthy'=0;;;; 'cluster_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Cluster $clustername is healthy|'cluster_healthy'=1;;;; 'cluster_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_OK}
  fi

fi
;;

# --- node status check --- #
node)
if [[ -z $clustername ]]; then 

# Check status of all nodes in all clusters
  api_out_nodes=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/nodes")
  declare -a node_names=( $(echo "$api_out_nodes" | jshon -e data -a -e nodeName -u) )
  declare -a node_status=( $(echo "$api_out_nodes" | jshon -e data -a -e state -u) )
  declare -a node_cluster_member=( $(echo "$api_out_nodes" | jshon -e data -a -e clusterId -u) )

  i=0
  for node in ${node_names[*]}
  do
    for status in ${node_status[$i]}
    do 
      if [[ ${status} != active ]]; then 
        nodeerrors[$i]="${node} in cluster ${node_cluster_member[$i]} is ${node_status[$i]} -"
      fi
    done
  let i++
  done

  if [[ ${#nodeerrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - ${nodeerrors[*]}|'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All ${#node_names[*]} nodes are active|'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;;"
    exit ${STATE_OK}
  fi

else 

# Check status of all nodes in a specific clusters
  api_out_nodes=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/nodes/?clusterId=${clustername}")

  # Check if that given cluster name exists
  if [[ -n $(echo "$api_out_nodes" | grep -i "error") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  declare -a node_names=( $(echo "$api_out_nodes" | jshon -e data -a -e nodeName -u) )
  declare -a node_status=( $(echo "$api_out_nodes" | jshon -e data -a -e state -u) )

  i=0
  for node in ${node_names[*]}
  do
    for status in ${node_status[$i]}
    do 
      if [[ ${status} != active ]]; then 
        nodeerrors[$i]="${node} in cluster ${clustername} is ${node_status[$i]} -"
      fi
    done
  let i++
  done

  if [[ ${#nodeerrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - ${nodeerrors[*]}|'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All ${#node_names[*]} nodes are active|'nodes_total'=${#node_names[*]};;;; 'node_errors'=${#nodeerrors[*]};;;;"
    exit ${STATE_OK}
  fi

fi
;;


# --- project status check --- #
project)
if [[ -z $projectname ]]; then 

# Check status of all projects
  api_out_project=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
  declare -a project_ids=( $(echo "$api_out_project" | jshon -e data -a -e id -u) )
  declare -a project_names=( $(echo "$api_out_project" | jshon -e data -a -e name -u) )
  declare -a cluster_ids=( $(echo "$api_out_project" | jshon -e data -a -e clusterId) )
  declare -a healthstatus=( $(echo "$api_out_project" | jshon -e data -a -e state -u) )
  
  for project in ${project_ids[*]}
  do
    i=0
    for status in ${healthstatus[*]}
    do 
      if [[ ${status} != active ]]; then 
        projecterrors[$i]="${project} in cluster ${cluster_ids[$i]} is not healthy"
      fi
    done
    let i++
  done

  if [[ ${#projecterrors[*]} -gt 0 ]]
  then 
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
  if [[ -n $(echo "$api_out_single_project" | grep -i "error") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Project $projectname not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_project" | jshon -e state -u)
  
  if [[ ${healthstatus} != active ]]
  then
    echo "CHECK_RANCHER2 CRITICAL - Project $projectname is not active|'project_active'=0;;;; 'project_error'=1;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Project $projectname is active|'project_active'=1;;;; 'project_error'=0;;;;"
    exit ${STATE_OK}
  fi
  

fi
;;

# --- workload status check (requires project)--- #
service) echo -e "CHECK_RANCHER2 UNKNOWN - In Rancher 2 services are called workloads. Use -t workload."; exit ${STATE_UNKNOWN}
;;
workload)
if [ -z $projectname ]; then echo -e "CHECK_RANCHER2 UNKNOWN - To check workloads you must also define the project (-p). This will check all workloads within the given project. To check a specific workload, define it with -w."; exit ${STATE_UNKNOWN}; fi
if [[ -z $workloadname ]]; then 

# Check status of all workloads within a project (project must be given)
  api_out_workloads=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads")

  if [[ -n $(echo "$api_out_workloads" | grep -i "ClusterUnavailable") ]]; then 
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  declare -a workload_names=( $(echo "$api_out_workloads" | jshon -e data -a -e name) )
  declare -a healthstatus=( $(echo "$api_out_workloads" | jshon -e data -a -e state -u) )
  declare -a pausedstatus=( $(echo "$api_out_workloads" | jshon -e data -a -s paused -u) )

  # We rather WARN than silently return OK for zero workloads
  if [[ ${#workload_names} -eq 0 ]]; then 
    echo "CHECK_RANCHER2 WARNING - No workloads found in project ${projectname}."; exit ${STATE_WARNING}
  fi
 
  i=0 
  for workload in ${workload_names[*]}
  do
    for status in ${healthstatus[$i]}
    do 
      if [[ ${status} = updating ]]; then 
        workloadwarnings[$i]="Workload ${workload} is ${status} -"
      elif [[ ${status} != active ]]; then
        workloaderrors[$i]="Workload ${workload} is ${status} -"
      fi
    done
    for paused in ${pausedstatus[$i]}
    do 
      if [[ ${paused} = true ]]; then 
        workloadpaused[$i]="${workload} "
      fi
    done
    let i++
  done

  if [[ ${#workloaderrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - ${workloaderrors[*]}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;;"
    exit ${STATE_CRITICAL}
  elif [[ ${#workloadwarnings[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 WARNING - ${workloadwarnings[*]}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;;"
    exit ${STATE_WARNING}
  else
    if [[ ${#workloadpaused[*]} -gt 0 ]]
      then echo "CHECK_RANCHER2 OK - All workloads (${#workload_names[*]}) in project ${projectname} are healthy/active ( Note: ${#workloadpaused[*]} workloads currently paused: ${workloadpaused[*]})|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;;"
      else echo "CHECK_RANCHER2 OK - All workloads (${#workload_names[*]}) in project ${projectname} are healthy/active|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;; 'workloads_warnings'=${#workloadwarnings[*]};;;; 'workloads_paused'=${#workloadpaused[*]};;;;"
    fi
    exit ${STATE_OK}
  fi

else
 
# Check status of a single workload
  api_out_single_workload=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads/?name=${workloadname}")

  if [[ -n $(echo "$api_out_single_workload" | grep -i "ClusterUnavailable") ]]; then 
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  # Check if that given project name exists
  if [[ -z $(echo "$api_out_single_workload" | grep -i "containers") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname not found."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_workload" | jshon -e data -a -e state -u)
  
  if [[ ${healthstatus} = updating ]]
  then 
    echo "CHECK_RANCHER2 WARNING - Workload $workloadname is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=0;;;; 'workload_warning'=1;;;;"
    exit ${STATE_WARNING}
  elif [[ ${healthstatus} != active ]]
  then
    echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=1;;;; 'workload_warning'=0;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Workload $workloadname is active|'workload_active'=1;;;; 'workload_error'=0;;;; 'workload_warning'=0;;;;"
    exit ${STATE_OK}
  fi
  
fi
;;

# --- pod status check (requires project) --- #
pod)
if [ -z $projectname ]; then echo -e "CHECK_RANCHER2 UNKNOWN - To check pods you must also define the project (-p). This will check all pods within the given project. To check a specific pod, define it with -o podname and -n namespace."; exit ${STATE_UNKNOWN}; fi
if [[ -z $podname ]]; then 

# Check status of all pods within a project (project must be given)
  api_out_pods=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/pods")

  if [[ -n $(echo "$api_out_pods" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  declare -a pod_names=( $(echo "$api_out_pods" | jshon -e data -a -e name) )
  declare -a healthstatus=( $(echo "$api_out_pods" | jshon -e data -a -e state -u) )

  # We rather WARN than silently return OK for zero pods
  if [[ ${#pod_names} -eq 0 ]]; then
    echo "CHECK_RANCHER2 WARNING - No pods found in project ${projectname}."; exit ${STATE_WARNING}
  fi

  i=0
  for pod in ${pod_names[*]}
  do
    for status in ${healthstatus[$i]}
    do
      if [[ ${status} != running && ${status} != succeeded ]]; then
        poderrors[$i]="Pod ${pod} is ${status} -"
      fi
    done
    let i++
  done

  if [[ ${#poderrors[*]} -gt 0 ]]
  then
    echo "CHECK_RANCHER2 CRITICAL - ${poderrors[*]}|'pods_total'=${#pod_names[*]};;;; 'pods_errors'=${#poderrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All pods (${#pod_names[*]}) in project ${projectname} are running|'pods_total'=${#pod_names[*]};;;; 'pods_errors'=${#poderrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
# Check status of a single pod (requires project and namespace)
# Note: This only makes sense when you create static pods!
  if [ -z $namespacename ]; then echo -e "CHECK_RANCHER2 UNKNOWN - To check a single pod you must also define the namespace (-n)."; exit ${STATE_UNKNOWN}; fi
  api_out_single_pod=$(curl -s ${selfsigned} -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/pods/${namespacename}:${podname}")

  if [[ -n $(echo "$api_out_single_pod" | grep -i "ClusterUnavailable") ]]; then
    clustername=$(echo ${projectname} | awk -F':' '{print $1}')
    echo "CHECK_RANCHER2 CRITICAL - Cluster $clustername not found. Hint: Use '-t info' to identify cluster and project names."; exit ${STATE_CRITICAL}
  fi

  # Check if that given project name exists
  if [[ -z $(echo "$api_out_single_pod" | grep -i "containers") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Pod $podname not found. Verify project (-p) and pod (-o) names."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_pod" | jshon -e state -u)

  if [[ ${healthstatus} != running ]]
  then
    echo "CHECK_RANCHER2 CRITICAL - Pod $podname is ${healthstatus}|'pod_active'=0;;;; 'pod_error'=1;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Pod $podname is running|'pod_active'=1;;;; 'pod_error'=0;;;;"
    exit ${STATE_OK}
  fi

fi
;;

esac
echo "UNKNOWN: should never reach this part"
exit ${STATE_UNKNOWN}
