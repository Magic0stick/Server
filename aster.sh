sudo virt-install \
  --name=freepbx17-asterisk \
  --vcpus=2 \
  --ram=4096 \
  --disk size=40,format=qcow2,bus=virtio \
  --network bridge=br0,model=virtio \
  --graphics vnc,listen=0.0.0.0 \
  --os-variant=debian12 \
  --cdrom=/var/lib/libvirt/images/debian-12.iso \
  --boot hd,cdrom
