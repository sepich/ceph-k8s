# Description
This is example of plain and simple deployment of Ceph to k8s you can use as a base. 
 - No `ceph-daemon` [bash magic](https://github.com/ceph/ceph-container/tree/master/src/daemon)
 - No `rook` operator magic

Just getting upstream `ceph` images and run them with arguments from docs. 
 - `mon`: 3 of them on 3 different master nodes. Because they are sensitive to IP/hostname be stable we run them in hostNet
 - `mgr`: 1 on any node
 - `mds`: 2 on different nodes (hot-stanby)
 - `osd`: one-per-disk, you can have any number of disks on nodes with different names. There is no auto-format, you will manually mark disks you want to use for Ceph.

# How to run
## Generate secrets:
Note we're use mimic image here to generate secrets for natilus. (Because nautilus image in `ceph-daemon` is broken)
```bash
docker run -it --rm --net=host --name ceph_mon -v `pwd`/etc:/etc/ceph -v `pwd`/var:/var/lib/ceph -e NETWORK_AUTO_DETECT=4 ceph/daemon:latest-mimic mon

kubectl -n ceph create cm fsid --from-literal=fsid=`awk '/fsid =/{print $3}' etc/ceph.conf`

kubectl -n ceph create secret generic ceph-etc --from-file=etc/ceph.client.admin.keyring --from-file=etc/ceph.mon.keyring
for d in osd mds rbd rgw; do
    kubectl -n ceph create secret generic ceph-bootstrap-${d}-keyring --from-file=var/bootstrap-${d}/ceph.keyring
done
```

## Deploy ceph
`kubectl -n ceph apply -f k8s/`

Wait till containers are up, and check that `mon` are in quorum:  
`kubectl -n ceph exec -it mgr-0 -- ceph -s`

## Prepare disks:
Scale tools deployment to span to all nodes:
```bash
kubectl -n ceph scale deployment tools --replicas=3  #number of k8s nodes
kubectl -n ceph get po -o wide
```
Now format each drive you want to use with ceph:
```
kubectl -n ceph exec -it tools-547559b7b5-6nllz -- ceph-volume inventory
kubectl -n ceph exec -it tools-547559b7b5-6nllz -- ceph-volume lvm prepare --bluestore --no-systemd --data /dev/sdf
```
At the same time daemonset `osd-discover` would monitor for newly formatted drives and create `osd` for each one. Please note that you need 4Gb RAM for each `osd`.

After you've done with initial disk formatting, you can disable `tools`.
After osd-discover created k8s pods for all OSD, you can disable `osd-discover` too:
```
kubectl -n ceph scale deployment tools --replicas=0
kubectl -n ceph delete ds osd-discover
```

## CephFS create
After you have `osd` ready:
```bash
kubectl -n ceph exec -it mgr-0 bash
ceph osd pool create cephfs_data 128
ceph osd pool set cephfs_data size 2       # replicas (default 3)
ceph osd pool set cephfs_data min_size 1   # accept io having at least this replicas (default 2)
ceph osd pool create cephfs_metadata 128
ceph fs new cephfs cephfs_metadata cephfs_data
ceph fs authorize cephfs client.k8s / rw   # it will print key for client.k8s, use it on next step
# Ctrl-D
kubectl create secret generic cephfs-secret --from-literal=key=AaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa==
```
Please note that by default cephfs fs has limit `max_file_size` of 1Tb, could be changed with:
```
ceph fs set cephfs max_file_size 1099511627776
```

Create dashboard user:
```
kubectl -n ceph exec -it mgr-0 -- ceph config set mgr mgr/dashboard/ssl false
kubectl -n ceph exec -it mgr-0 -- ceph dashboard ac-user-create <username> <password> administrator
kubectl -n ceph exec -it mgr-0 -- ceph dashboard feature disable mirroring iscsi rbd rgw
```

Verify that mons are listening on v1 port 6789 (for CephFS kernel-client mounting):
```bash
kubectl -n ceph exec -it mgr-0 -- ceph mon dump
# Change if needed:
kubectl -n ceph exec -it mgr-0 -- ceph mon set-addrs hostname [v2:10.2.3.4:3300,v1:10.2.3.4:6789]
...
```
## Mount CephFS to host
This is just an example how you can mount CephFS on k8s host. This is not needed for mounting inside of containers.
```bash
echo 'AaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa==' > /root/.ceph

mkdir /mnt/ceph
mount -t ceph -o 'name=k8s,secretfile=/root/.ceph' <master-hostname>:/ /mnt/ceph
```

## Use CephFS in Pods
Example PV and PVC without dynamic provisioning:
```yml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  labels:
    namespace: default
  name: data
spec:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: 10Gi
  cephfs:
    monitors:
    - master1.hostname
    - master2.hostname
    - master3.hostname
    path: /data
    secretRef:
      name: cephfs-secret
    user: k8s
  storageClassName: data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: logs
```
More info: https://github.com/kubernetes/examples/tree/master/volumes/cephfs/

For dynamic provisioing CSI example provided as `k8s/6-csi.yml.example` (disabled by default)

## Remove/reuse disk

If you need to remove/reuse/swap disk:
```
ceph osd out osd.1
ceph osd purge osd.1 --yes-i-really-mean-it
ceph osd status

kubectl -n ceph delete deploy osd-1
kubectl -n ceph exec -it tools-547559b7b5-6nllz -- ceph-volume lvm zap --destroy /dev/sdf
```
