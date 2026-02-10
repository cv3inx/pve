# Proxmox VE Docker Deployment Script

Quick deploy Proxmox VE in Docker with full LXC support and auto-configuration.

## ✨ Features

### Core Features
- ✅ Custom Proxmox version support
- ✅ Auto network bridge configuration (vmbr0)
- ✅ Complete LXC/LXD container support
- ✅ Auto-detect and auto-start new LXC containers
- ✅ LXCFS patching for nested containers
- ✅ Kernel modules auto-loading
- ✅ NAT/Masquerading for internet access
- ✅ Subscription notice disabled
- ✅ Clean minimal UI with progress indicators

### LXC Features
- ✅ **Auto-watch service** - Automatically detects new LXC containers
- ✅ **Auto-configure** - Sets up networking and permissions automatically
- ✅ **Auto-start** - Starts containers automatically
- ✅ **Full nested support** - Run containers inside containers
- ✅ **Network isolation** - Each LXC gets its own network namespace

### Technical Features
- ✅ Docker capabilities: NET_ADMIN, SYS_ADMIN
- ✅ TUN/TAP device support
- ✅ iptables-persistent for rules persistence
- ✅ System limits auto-configuration (inotify)
- ✅ Kernel modules: loop, nf_nat, ip_tables, iptable_nat, overlay
- ✅ Volume persistence for /var/lib/pve and /var/lib/vz

## 🚀 Quick Start

### Install

```bash
# Download script
chmod +x proxmox-deploy.sh

# Deploy with default version (9.1.4)
./proxmox-deploy.sh

# Deploy specific version
./proxmox-deploy.sh 9.1.4
```

### Access

After deployment completes:

```
URL      : https://YOUR_IP:8006
Username : root
Password : root
```

**Note:** Accept SSL warning in browser (self-signed certificate)

## 📋 Requirements

- Docker installed and running
- Port 8006 available
- Root/sudo access (for inotify limits configuration)
- Linux kernel with:
  - Namespace support
  - Cgroup support
  - Bridge support

## 🐳 Using LXC Containers

### Method 1: Auto-watch (Recommended)

1. Open Proxmox Web UI
2. Click "Create CT"
3. Choose template and configure resources
4. **Network:** Set Bridge to `vmbr0` and enable DHCP
5. Click Create
6. **Auto-watch will automatically:**
   - Detect the new container
   - Configure networking
   - Set AppArmor profile
   - Start the container
   - Assign IP address

### Method 2: Manual

```bash
# Setup specific container
docker exec proxmoxve lxc-manager.sh setup 100

# Setup all containers
docker exec proxmoxve lxc-manager.sh setup-all

# Check status
docker exec proxmoxve lxc-manager.sh status
```

## 🔧 Advanced Configuration

### Change Network Range

Default network: `10.10.10.0/24`

To change, modify the script before running:
```bash
# In configure_network() function
address 10.10.10.1/24  →  address 192.168.100.1/24
```

### Add More Volumes

```bash
docker run ... \
  -v /path/on/host:/path/in/container \
  ...
```

### Custom Port

```bash
# Change PORT variable in script
PORT="8006"  →  PORT="8080"
```

## 📦 Installed Packages

### Essential Tools
- curl, wget, vim, nano
- net-tools, iputils-ping, dnsutils
- htop, rsync, gnupg

### LXC/Virtualization
- lxc, lxcfs, lxc-templates
- debootstrap
- bridge-utils, vlan, ifupdown2

### Networking
- iptables, iptables-persistent
- iproute2, tcpdump, nmap, netcat

## 🛠️ Useful Commands

### Container Management
```bash
# Access shell
docker exec -it proxmoxve bash

# View logs
docker logs proxmoxve
docker logs -f proxmoxve  # Follow logs

# Restart container
docker restart proxmoxve

# Stop/Start
docker stop proxmoxve
docker start proxmoxve
```

### LXC Management
```bash
# Watch auto-detect logs
docker exec proxmoxve journalctl -u lxc-autowatch -f

# List all LXC containers
docker exec proxmoxve lxc-ls -f

# Check LXC info
docker exec proxmoxve lxc-info -n 100
```

### Networking
```bash
# Check bridge status
docker exec proxmoxve ip addr show vmbr0

# Check NAT rules
docker exec proxmoxve iptables -t nat -L -n -v

# Check routing
docker exec proxmoxve ip route
```

## 🔍 Troubleshooting

### Container won't start
```bash
# Check logs
docker logs proxmoxve

# Check systemd status
docker exec proxmoxve systemctl status

# Restart services
docker exec proxmoxve systemctl restart pveproxy pvedaemon
```

### LXC container issues
```bash
# Check LXCFS
docker exec proxmoxve systemctl status lxcfs

# Check auto-watch
docker exec proxmoxve systemctl status lxc-autowatch

# Manual start LXC
docker exec proxmoxve lxc-start -n 100 -F  # Foreground mode for debugging
```

### Network issues
```bash
# Check bridge
docker exec proxmoxve brctl show

# Check IP forwarding
docker exec proxmoxve sysctl net.ipv4.ip_forward

# Restart networking
docker exec proxmoxve systemctl restart networking
```

### Port already in use
```bash
# Find process using port 8006
sudo lsof -i :8006
sudo netstat -tlnp | grep 8006

# Change port in script or stop conflicting service
```

## 📝 Script Components

### Deployment Steps (13 total)
1. ✅ Check system limits (inotify)
2. ✅ Check requirements (Docker, port)
3. ✅ Check existing container
4. ✅ Deploy container (pull image + create)
5. ✅ Configure network bridge (vmbr0)
6. ✅ Disable subscription notice
7. ✅ Update system packages
8. ✅ Install dependencies
9. ✅ Configure LXC support (LXCFS, modules)
10. ✅ Install LXC manager (auto-watch)
11. ✅ Configure Proxmox storage
12. ✅ Finalize setup
13. ✅ Complete

### Services Created
- **lxc-autostart.service** - Auto-setup all LXC on boot
- **lxc-autowatch.service** - Auto-detect and setup new LXC

## 🔒 Security Notes

- Default credentials: root/root - **CHANGE IMMEDIATELY**
- Self-signed SSL certificate - Expected browser warning
- Privileged container - Required for LXC support
- NAT enabled - LXC containers can access internet
- AppArmor disabled for LXC - Required for nested containers

## 🐛 Known Issues

1. **Browser SSL Warning** - Normal, self-signed cert
2. **First boot slow** - Systemd initialization takes time
3. **Memory usage high** - Proxmox is memory-intensive

## 📄 License
Free to use and modify.

## 

- Check deployment log: `/tmp/proxmox-deploy-YYYYMMDD-HHMMSS.log`
- Run with `--help` for usage info
- Check Docker logs for runtime issues

---
