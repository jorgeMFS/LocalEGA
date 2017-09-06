#cloud-config
write_files:
  - encoding: b64
    content: ${boot_script}
    owner: root:root
    path: /root/boot.sh
    permissions: '0700'
  - encoding: b64
    content: ${lega_script}
    owner: ega:ega
    path: /home/ega/boot.sh
    permissions: '0700'
  - encoding: b64
    content: ${hosts}
    owner: root:root
    path: /etc/hosts
    permissions: '0644'
  - encoding: b64
    content: ${conf}
    owner: ega:ega
    path: /home/ega/.lega/conf.ini
    permissions: '0600'
  - encoding: b64
    content: ${ega_service}
    owner: root:root
    path: /etc/systemd/system/ega-inbox.service
    permissions: '0644'

runcmd:
  - /root/boot.sh "${cidr}"
  - su -c '/home/ega/boot.sh' - ega


final_message: "The system is finally up, after $UPTIME seconds"