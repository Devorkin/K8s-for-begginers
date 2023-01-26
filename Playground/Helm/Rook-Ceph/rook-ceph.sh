#! /bin/bash

# Dependecy checks and variables declaration
which helm &>/dev/null
if [[ $? != 0 ]]; then
  echo -e "`date +"%d-%m-%y %H:%M:%S"`\tHelm is missing!" | tee -a /var/log/k8s-rook-ceph.log
  exit 1
fi

NODES_COUNT=$(kubectl get nodes --no-headers=true | grep -v control-plane | wc -l)
if [ ! $NODES_COUNT -gt 3 ]; then
  echo -e "`date +"%d-%m-%y %H:%M:%S"`\tCeph setup requires at least 4 nodes, currently there are ${NODES_COUNT} registered, please enlarge your K8s cluster" | tee -a /var/log/k8s-rook-ceph.log
  exit 2
fi

if [ ! -z $1 ]; then
  if [ -f $1/Helm/Rook-Ceph/values.yaml ]; then
    playground_dir=$1
  else
    echo -e "`date +"%d-%m-%y %H:%M:%S"`\tCould not validate the $1 path -- Looking for the Playground directory path" | tee -a /var/log/k8s-rook-ceph.log
    exit 3
  fi
else
  CPWD=$(basename $(pwd))
  if [ -f Helm/Rook-Ceph/values.yaml ]; then
    playground_dir="."
  elif [[ $CPWD == "K8s-for-begginers" ]]; then
    playground_dir="./Playground"
  else
    read -p 'Enter the path to the Playground directory: ' playground_dir
    if [ ! -f $playground_dir/Helm/Rook-Ceph/values.yaml ]; then
      echo -e "`date +"%d-%m-%y %H:%M:%S"`\tCould not validate $playground_dir path" | tee -a /var/log/k8s-rook-ceph.log
      exit 3
    fi
  fi
fi
echo "All goes well" | tee -a /var/log/k8s-rook-ceph.log
exit 99
### TODO
# Confirm that the cluster has more than 3 serving nodes
# Confirm that these nodes has atleast 1 additional disk device - which is not in use and there's no filesystem on it
# Apply ConfigMap override to fix clock drift bug with ceph based on VMs
# Source code: $playground_dir/Yamls/Rook-Ceph/rook-ConfigMap-config-override.yaml
###

if ! kubectl get priorityclass | grep high-priority &> /dev/null; then kubectl crete -f $playground_dir/Yamls/Default/PriorityClasses/default.yaml; fi
helm repo add rook-release https://charts.rook.io/release
helm install --create-namespace --namespace rook-ceph rook-ceph rook-release/rook-ceph -f $playground_dir/Helm/Rook-Ceph/values.yaml
kubectl wait -n rook-ceph pod -l app=rook-ceph-operator --for condition=Ready --timeout=300s
kubectl create -f $playground_dir/Yamls/Rook-Ceph/cluster.yaml

while ! kubectl wait pod -n rook-ceph -l mon=a --for condition=Ready --timeout=600s; do sleep 10; done
while ! kubectl wait pod -n rook-ceph -l mon=b --for condition=Ready --timeout=600s; do sleep 10; done
while ! kubectl wait pod -n rook-ceph -l mon=c --for condition=Ready --timeout=600s; do sleep 10; done
while ! kubectl wait pod -n rook-ceph -l app=csi-rbdplugin --for condition=Ready --timeout=600s; do sleep 10; done
while ! kubectl wait pod -n rook-ceph -l app=csi-cephfsplugin --for condition=Ready --timeout=600s; do sleep 10; done
while ! kubectl wait -n rook-ceph pod -l osd=2 --for condition=Ready --timeout=600s; do sleep 10; done
kubectl patch -n rook-ceph configmap rook-config-override -p '{"data": {"config":"[global]\nmon clock drift allowed = 5"}}'

kubectl create -f $playground_dir/Yamls/Rook-Ceph/toolbox.yaml
kubectl wait -n rook-ceph pod -l app=rook-ceph-tools --for condition=Ready --timeout=120s

# Setup Ceph RBD Block StorageClass
kubectl create -f $playground_dir/Yamls/Rook-Ceph/block-storageclass.yaml
while ! kubectl get storageclass -n rook-ceph rook-ceph-block &> /dev/null; do sleep 10; done

# Setup Ceph Filesystem StorageClass
kubectl create -f $playground_dir/Yamls/Rook-Ceph/cephfs-filesystem.yaml
while ! kubectl get -n rook-ceph CephFilesystem rook-ceph-cephfs &> /dev/null; do sleep 10; done
while ! kubectl wait -n rook-ceph pods -l ceph_daemon_type=mds --for condition=Ready --timeout=300s; do sleep 10; done
kubectl create -f $playground_dir/Yamls/Rook-Ceph/cephfs-storageclass.yaml
while ! kubectl get storageclass -n rook-ceph rook-ceph-filesystem &> /dev/null; do sleep 10; done

# Setup Ceph CSI Object StorageClass
kubectl create -f $playground_dir/Yamls/Rook-Ceph/object-store.yaml
while ! kubectl get -n rook-ceph CephObjectStore rook-ceph-object-store | grep Ready &> /dev/null; do sleep 60; done
kubectl wait -n rook-ceph pod -l app=rook-ceph-rgw --for condition=ready --timeout=300s
kubectl create -f $playground_dir/Yamls/Rook-Ceph/object-bucket-storageclass.yaml
while ! kubectl get storageclass -n rook-ceph rook-ceph-bucket &> /dev/null; do sleep 10; done

if [ -f /etc/cron.d/rook-ceph-setup ]; then rm -f /etc/cron.d/rook-ceph-setup; fi
