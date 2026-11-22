# Runbooks

All commands assume `live/lab` and admin credentials for the account.
`PREFIX=/kube-ec2/lab` and `RT=$(aws ssm get-parameter --name $PREFIX/30-cluster/runtime_ssm_prefix --query Parameter.Value --output text)`.

## Watch a node bootstrap

```bash
aws ssm start-session --target i-0123...
sudo journalctl -u k8s-bootstrap -f        # init/join progress
sudo cat /etc/k8s-bootstrap/cluster.env    # what user data told it
```

## Break-glass kubectl

```bash
./scripts/get-kubeconfig.sh lab            # writes ~/.kube/kube-ec2-lab.conf
./scripts/get-kubeconfig.sh lab tunnel     # keep running
KUBECONFIG=~/.kube/kube-ec2-lab.conf kubectl get nodes
```

The parameter holds a cluster-admin credential (group `kubeadm:cluster-admins`).
Reads are logged in CloudTrail. Set up OIDC for humans via GitOps and keep this
for emergencies.

## Roll nodes onto a new AMI

1. Merge the `node-ami` bot PR after `atlantis apply`. Worker pools roll
   themselves (instance refresh, 66% min healthy per AZ, drained through
   node-termination-handler).
2. Control plane: `./scripts/roll-control-plane.sh lab` (one node at a time,
   waits for 3 Ready nodes and healthy etcd between nodes).

## Kubernetes minor upgrade (e.g. 1.36 → 1.37)

kubeadm upgrades are in-place for the cluster's stored configuration, so the
first step happens on a running control-plane node:

1. Build an AMI for the new minor (`node-ami` workflow, input
   `kubernetes_minor=1.37`), but **don't merge the PR yet**.
2. On one control-plane node: install the new `kubeadm` only, then
   `kubeadm upgrade plan` and `kubeadm upgrade apply v1.37.x`. This updates
   the `kubeadm-config`/`kubelet-config` ConfigMaps and static pods on that node.
3. Upgrade the add-ons that need it (Cilium, CCM) through GitOps.
4. Merge and apply the AMI PR, then `roll-control-plane.sh`: replacements
   join with the new version. Workers roll after.

Never skip a minor; the version skew policy allows kubelets at most 3 minors
behind the API server, but control-plane components must step one minor at a
time.

## A control-plane node died

Nothing to do: its ASG replaces it. Survivors' `k8s-etcd-reconcile.timer`
removes the dead etcd member (instance gone **and** endpoint unreachable), and
the newcomer's join retries until etcd accepts it. Watch with:

```bash
kubectl -n kube-system exec etcd-<node> -- etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  member list -w table
```

## The first node failed during `kubeadm init`

The init lock is held by a node that never finished, so every other control-plane
node waits on `$RT/initialized` and eventually fails. For a cluster that never
initialized:

```bash
aws ssm delete-parameters --names $RT/init-lock $RT/join/certificate-key $RT/secrets/encryption-key
# then terminate all three control-plane instances; the ASGs relaunch them
```

Never do this on a cluster that was initialized (`$RT/initialized` exists):
that's the disaster-recovery path below.

## Lost quorum (2 or 3 control-plane nodes gone at once)

etcd cannot recover by itself. Restore from snapshot:

1. Scale the control-plane ASGs to 0 (or stop the instances).
2. Pick the newest good snapshot:
   `aws s3 ls s3://<etcd-backup-bucket>/<cluster>/<generation>/ --recursive | sort | tail`.
3. Start one control-plane node with a restore hook: on it, stop kubelet,
   `etcdutl snapshot restore` into `/var/lib/etcd` with
   `--initial-cluster <name>=https://<ip>:2380`, start kubelet.
4. Once the API is up, remove stale members, then let the other two ASGs
   launch replacements; they join normally.
5. Rehearse this in the lab before you need it.

## Rotate the Atlantis instance

```bash
cd live/lab/05-atlantis
terraform apply -var-file=../common.tfvars -replace=module.atlantis.aws_instance.atlantis
```

Atlantis' locks live on the instance; finish or discard open PR plans first.

## Tear down the lab (reverse order)

```bash
# via Atlantis or locally, in this order:
50-platform-iam → 40-edge (set public_deletion_protection=false first) → 30-cluster → 20-identity → 10-network
# then locally: 05-atlantis. Keep 00-bootstrap (state) unless you are done for good.
```
