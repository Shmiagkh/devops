#!/bin/bash

set -e

# Prompt for user input
read -p "Enter the SSH username for nodes: " SSH_USER
read -p "Enter space-separated IP addresses or hostnames of the nodes: " -a NODE_IPS

PLAYBOOK_PATH="./node_install.yaml"
INVENTORY_FILE="./inventory.ini"
PROMETHEUS_TARGETS_FILE="./prometheus/prometheus_targets.yml"
PROMETHEUS_CONFIG_FILE="./prometheus/prometheus.yml"

# prometheus directory
if [ ! -d "prometheus" ]; then
  mkdir prometheus
fi
chmod 777 prometheus

# prometheus-data directory
if [ ! -d "prometheus-data" ]; then
  mkdir prometheus-data
fi
chmod 777 prometheus-data

# grafana-data directory
if [ ! -d "grafana-data" ]; then
  mkdir grafana-data
fi
chmod 777 grafana-data

# snmp directory
if [ ! -d "snmp" ]; then
  mkdir snmp
fi
chmod 777 snmp

# grafana directory
if [ ! -d "grafana" ]; then
  mkdir grafana
fi
chmod 777 grafana

cat <<EOF > "snmp_exporter.yaml"
---
services:
  snmp-exporter:
    container_name: snmp-exporter
    image: quay.io/prometheus/snmp-exporter:v0.26.0
    ports:
      - "9116:9116"
      - "161:161/udp"
    volumes:
      - ./snmp:/etc/snmp-exporter
    command: --config.file=/etc/snmp-exporter/snmp.yml
    restart: unless-stopped
    networks:
      prometheus_frontend:
        ipv4_address: 172.19.0.12

networks:
  prometheus_frontend:
    external: true
EOF

cat <<EOF > "./prometheus/prometheus.yaml"
---
services:
  prometheus:
    image: prom/prometheus:v2.53.0
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - .:/etc/prometheus
      - .:/prometheus
    command: "--config.file=/etc/prometheus/prometheus.yml"
    restart: unless-stopped
    networks:
      frontend:
        ipv4_address: 172.19.0.11

networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.19.0.0/16
          gateway: 172.19.0.1
EOF

cat <<EOF > "grafana.yaml"
---
services:
  grafana:
    image: grafana/grafana-oss:10.2.8
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./grafana:/etc/grafana/provisioning/datasources
    restart: unless-stopped
    networks:
      prometheus_frontend:
        ipv4_address: 172.19.0.13

networks:
  prometheus_frontend:
    external: true
EOF

cat <<EOF > "./grafana/datasource_prometheus.yaml"
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    jsonData:
      httpMethod: GET
    version: 1
    readOnly: false
EOF
cat <<EOF > "$PLAYBOOK_PATH"
---
- name: Install Node Exporter on target hosts
  hosts: all
  become: yes
  vars:
    node_exporter_version: "1.6.1"
    node_exporter_user: "node_exporter"
    node_exporter_group: "node_exporter"
    node_exporter_install_dir: "/usr/local/bin"
    node_exporter_service_path: "/etc/systemd/system/node_exporter.service"
    ansible_become_pass: "11"

  tasks:
    - name: Create node_exporter system group
      group:
        name: "{{ node_exporter_group }}"
        state: present

    - name: Create node_exporter system user
      user:
        name: "{{ node_exporter_user }}"
        group: "{{ node_exporter_group }}"
        system: yes
        shell: /usr/sbin/nologin
        create_home: no
        state: present

    - name: Download Node Exporter binary archive
      get_url:
        url: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
        dest: "/tmp/node_exporter.tar.gz"
        mode: '0644'

    - name: Extract Node Exporter binary
      unarchive:
        src: "/tmp/node_exporter.tar.gz"
        dest: "/tmp"
        remote_src: yes
        creates: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"

    - name: Install Node Exporter binary
      copy:
        src: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
        dest: "{{ node_exporter_install_dir }}/node_exporter"
        remote_src: yes
        mode: '0755'
        owner: root
        group: root

    - name: Clean up temporary files
      file:
        path: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64"
        state: absent
      ignore_errors: yes

    - name: Clean up archive
      file:
        path: "/tmp/node_exporter.tar.gz"
        state: absent
      ignore_errors: yes

    - name: Create systemd service file for Node Exporter
      copy:
        dest: "{{ node_exporter_service_path }}"
        mode: '0644'
        content: |
          [Unit]
          Description=Node Exporter
          Wants=network-online.target
          After=network-online.target

          [Service]
          User={{ node_exporter_user }}
          Group={{ node_exporter_group }}
          Type=simple
          ExecStart={{ node_exporter_install_dir }}/node_exporter

          [Install]
          WantedBy=multi-user.target

    - name: Reload systemd daemon
      systemd:
        daemon_reload: yes

    - name: Enable and start Node Exporter service
      systemd:
        name: node_exporter
        enabled: yes
        state: started

    - name: Confirm Node Exporter is active and listening
      ansible.builtin.shell: "ss -tunelp | grep node_exporter"
      register: ss_output
      changed_when: false
      failed_when: ss_output.rc != 0
      check_mode: no

    - name: Debug Node Exporter listening status
      debug:
        msg: "Node Exporter is running and listening on the expected ports."
EOF

#soft install

if command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt-get"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
else
  echo "No supported package manager found (apt-get, dnf, yum). Exiting."
  exit 1
fi

case $PKG_MANAGER in
  apt-get)
    sudo apt-get update
    sudo apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      software-properties-common \
      docker-compose \
      openssh-server \
      ansible
    ;;
  dnf)
    sudo dnf install -y \
      curl \
      device-mapper-persistent-data \
      lvm2 \
      docker-compose \
      openssh-server \
      ansible
    ;;
  yum)
    sudo yum install -y \
      curl \
      device-mapper-persistent-data \
      lvm2 \
      docker-compose \
      openssh-server \
      ansible
    ;;
esac

#creating key

if [ ! -f ~/.ssh/id_rsa.pub ]; then
  echo "No SSH key found, generating one..."
  ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa
else
  echo "Existing SSH key found."
fi

for ip in "${NODE_IPS[@]}"; do
  echo "Copying SSH key to $SSH_USER@$ip..."
  ssh-copy-id -o StrictHostKeyChecking=no "$SSH_USER@$ip"
done

echo "[*] Creating Ansible inventory file inventory.ini..."

{
  echo "[nodes]"
  for ip in "${NODE_IPS[@]}"; do
    echo "$ip ansible_user=$SSH_USER"
  done
} > inventory.ini

echo "Generated inventory.ini:"
cat inventory.ini

echo "[*] Running Ansible playbook $PLAYBOOK_PATH..."

ansible-playbook -i inventory.ini "$PLAYBOOK_PATH"

# Script to extract node IPs from Ansible inventory, save to targets file, and configure Prometheus scrape targets.

mapfile -t NODE_IPS < <(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$INVENTORY_FILE" | sort -u)

if [ ${#NODE_IPS[@]} -eq 0 ]; then
  echo "No IP addresses found in inventory file: $INVENTORY_FILE"
  exit 1
fi

# Create Prometheus targets.yml content
{
  echo "-"
  echo "  targets:"
  # Format each IP as - "ip:9100"
  for ip in "${NODE_IPS[@]}"; do
    echo "    - \"$ip:9100\""
  done
} > "$PROMETHEUS_TARGETS_FILE"

sudo chown prometheus:prometheus "$PROMETHEUS_TARGETS_FILE"

cat <<EOF >"$PROMETHEUS_CONFIG_FILE"
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    file_sd_configs:
      - files:
          - '/etc/prometheus/prometheus_targets.yml'
EOF

docker-compose -f ./prometheus/prometheus.yaml up -d
docker-compose -f grafana.yaml -f snmp_exporter.yaml up -d
