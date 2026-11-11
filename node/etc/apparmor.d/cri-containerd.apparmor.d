# containerd's default container profile, with a fix for Ubuntu kernel >= 7.0.0-41.
#
# Installed on the node as /etc/apparmor.d/cri-containerd.apparmor.d. See
# "AppArmor: containerd profile" in docs/node-setup.md.
#
# Why this file exists: kernel 7.0.0-41 (CVE-2026-90231) plus Ubuntu's default
# kernel.apparmor_restrict_unprivileged_unconfined=1 turn runc's switch into
# this profile into a stack, so container processes are labelled
# "cri-containerd.apparmor.d//&unconfined". containerd's rule below only allows
# signals to the plain name, so every signal inside a container is denied and
# Postgres crash-loops ("could not signal for checkpoint: Permission denied").
#
#   https://github.com/containerd/containerd/issues/14485
#   https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2172422
#   https://github.com/cloudnative-pg/cloudnative-pg/issues/11343
#
# containerd only loads its built-in profile when none named
# cri-containerd.apparmor.d is loaded yet, so this file (loaded at boot by
# apparmor.service, before k3s starts) replaces it. Everything except the two
# "stacked" lines is containerd v2.2.2's contrib/apparmor/template.go, rendered
# as containerd renders it on this node (k3s v1.34.6, containerd 2.2.2).
#
# Remove this file once a k3s release ships containerd with the upstream fix.

abi <abi/3.0>,

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # Added: the same, for the stacked label the >= 7.0.0-41 kernel gives them.
  signal (send,receive) peer="cri-containerd.apparmor.d//&unconfined",

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/mem rwklx,
  deny @{PROC}/kmem rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  # Added: the same, for the stacked label.
  ptrace (trace,tracedby,read,readby) peer="cri-containerd.apparmor.d//&unconfined",
}
