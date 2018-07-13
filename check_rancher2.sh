#!/bin/bash 
##########################################################################################
# Script/Plugin: check_rancher2.sh                                                       #
# Author:        Claudio Kuenzler                                                        #
# Official repo: https://github.com/Napsty/check_rancher2                                #
# Documentation: https://www.claudiokuenzler.com/monitoring-plugins/check_rancher2.php   #
# Purpose:       Monitor Rancher 2.x container envioronments                             #
# Description:   Checks status of resources within the Kubernetes environment(s)         #
#                using the Rancher 2.x API                                               #
# License :      GNU General Public Licence (GPL) http://www.gnu.org/                    #
# This program is free software; you can redistribute it and/or modify it under the      #
# terms of the GNU General Public License as published by the Free Software Foundation;  #
# either version 2 of the License, or (at your option) any later version.                #
# This program is distributed in the hope that it will be useful, but WITHOUT ANY        #
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A        #
# PARTICULAR PURPOSE.  See the GNU General Public License for more details.              #
# You should have received a copy of the GNU General Public License along with this      #
# program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street,      #
# Fifth Floor, Boston, MA, 02110-1301, USA.                                              #
#											 #
# History:                                                                               #
# 20180629 alpha Started programming of script                                           #
# 20180713 beta1 Public release in repository                                            #
##########################################################################################
# todos: 
# - check type: nodes (inside a given cluster) 
# - documentation
##########################################################################################
# (Pre-)Define some fixed variables
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH # Set path
proto=http		# Protocol to use, default is http, can be overwritten with -S parameter

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
help="check_rancher2 (c) 2018 Claudio Kuenzler (published under GPLv2)\n
Usage: $0 -H Rancher2Address -U user-token -P password [-S] -t checktype [-c cluster] [-p project] [-w workload]\n
\nOptions:\n
\t-H Address of Rancher 2 API (e.g. rancher.example.com)\n
\t-U API username (Access Key)\n
\t-P API password (Secret Key)\n
\t-S Use https instead of http\n
\t-t Check type (see list below for available check types)\n
\t-c Cluster name (for specific cluster check)\n
\t-p Project name (for specific project check, needed for workload checks)\n
\t-w Workload name (for specific workload check)\n
\t-h Help. I need somebody. Help. Not just anybody. Heeeeeelp!\n
\nCheck Types:\n
\tinfo -> Informs about available clusters and projects and their API ID's. These ID's are needed for specific checks.\n
\tcluster -> Checks the current status of all clusters or of a specific cluster (defined with -c clusterid)\n
\tproject -> Checks the current status of all projects or of a specific project (defined with -p projectid)\n
\tworkload -> Checks the current status of all or a specific (-w workloadname) workload within a project (-p projectid must be set!)\n
\n"

if [ "${1}" = "--help" -o "${#}" = "0" ];
       then echo -e ${help}; exit 1;
fi
#########################################################################
# Get user-given variables
while getopts "H:U:P:t:c:p:w:Sh" Input;
do
  case ${Input} in
  H)      apihost=${OPTARG};;
  U)      apiuser=${OPTARG};;
  P)      apipass=${OPTARG};;
  t)      type=${OPTARG};;
  c)      clustername=${OPTARG};;
  p)      projectname=${OPTARG};;
  w)      workloadname=${OPTARG};;
  S)      proto=https;;
  h)      echo -e ${help}; exit ${STATE_UNKNOWN};;
  *)      echo -e ${help}; exit ${STATE_UNKNOWN};;
  esac
done
#########################################################################
# Did user obey to usage?
if [ -z $apihost ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing Rancher 2.x API host address"; exit ${STATE_UNKNOWN}; fi
if [ -z $apiuser ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing API user"; exit ${STATE_UNKNOWN}; fi
if [ -z $apipass ]; then echo -e "CHECK_RANCHER2 UNKNOWN - Missing API password"; exit ${STATE_UNKNOWN}; fi
#########################################################################
# Base communication check
apicheck=$(curl -s -o /dev/null -w "%{http_code}" -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")

# Detect failures
if [[ $apicheck = 301 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 302 ]]
then echo -e "CHECK_RANCHER2 UNKNOWN - Redirect detected. Maybe http to https? Use -S parameter."; exit ${STATE_UNKNOWN}
elif [[ $apicheck = 401 ]]
then echo -e "CHECK_RANCHER2 WARNING - Authentication failed"; exit ${STATE_WARNING}
fi
#########################################################################
# Do the checks
case ${type} in 

# --- info --- #
info)
api_out_clusters=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters")
api_out_project=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
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
  api_out_clusters=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters")
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
  api_out_single_cluster=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/clusters/${clustername}")

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
    echo "CHECK_RANCHER2 OK - Cluster $clustername is healthy|'cluster_healthy'=0;;;; 'cluster_errors'=${#componenterrors[*]};;;;"
    exit ${STATE_OK}
  fi

fi
;;

# --- project status check --- #
project)
if [[ -z $projectname ]]; then 

# Check status of all projects
  api_out_project=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project")
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
  api_out_single_project=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}")

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
service) echo -e "CHECK_RANCHER2 UNKNOWN - Rancher 2 calls services workloads. Use -t workload."; exit ${STATE_UNKNOWN}
;;
workload)
if [ -z $projectname ]; then echo -e "CHECK_RANCHER2 UNKNOWN - To check workloads you must also define the project (-p). This will check all workloads within the given project. To check a specific workload, define it with -w."; exit ${STATE_UNKNOWN}; fi
if [[ -z $workloadname ]]; then 

# Check status of all workloads within a project (project must be given)
  api_out_workloads=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads")
  #declare -a workload_ids=( $(echo "$api_out_workloads" | jshon -e data -a -e id) ) # Not needed
  declare -a workload_names=( $(echo "$api_out_workloads" | jshon -e data -a -e name) )
  declare -a healthstatus=( $(echo "$api_out_workloads" | jshon -e data -a -e state -u) )
  
  for workload in ${workload_names[*]}
  do
    i=0
    for status in ${healthstatus[*]}
    do 
      if [[ ${status} != active ]]; then 
        workloaderrors[$i]="Workload ${workload} is ${status} -"
      fi
    done
    let i++
  done

  if [[ ${#workloaderrors[*]} -gt 0 ]]
  then 
    echo "CHECK_RANCHER2 CRITICAL - ${workloaderrors[*]}|'workloads_total'=${#workload_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - All workloads (${#workload_names[*]}) are healthy|'workloads_total'=${#workloads_names[*]};;;; 'workloads_errors'=${#workloaderrors[*]};;;;"
    exit ${STATE_OK}
  fi

else
 
# Check status of a single workload
  api_out_single_workload=$(curl -s -u "${apiuser}:${apipass}" "${proto}://${apihost}/v3/project/${projectname}/workloads/?name=${workloadname}")

  # Check if that given project name exists
  if [[ -z $(echo "$api_out_single_workload" | grep -i "containers") ]]
    then echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname not found."; exit ${STATE_CRITICAL}
  fi

  healthstatus=$(echo "$api_out_single_workload" | jshon -e data -a -e state -u)
  
  if [[ ${healthstatus} != active ]]
  then
    echo "CHECK_RANCHER2 CRITICAL - Workload $workloadname is ${healthstatus}|'workload_active'=0;;;; 'workload_error'=1;;;;"
    exit ${STATE_CRITICAL}
  else
    echo "CHECK_RANCHER2 OK - Workload $workloadname is active|'workload_active'=1;;;; 'workload_error'=0;;;;"
    exit ${STATE_OK}
  fi
  

fi
;;

esac
echo "UNKNOWN: should never reach this part"
exit ${STATE_UNKNOWN}
