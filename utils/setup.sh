#!/bin/sh

# Default values.
VMCOUNT="40"
ISOFILE=""
SERIALKEY=""
TMPFSSIZE=""

usage() {
    echo "Usage: $0 [options...]"
    echo "-c --vmcount: Amount of Virtual Machines to be created."
    echo "-i --iso: Path to a Windows XP Installer ISO."
    echo "-s --serial-key: Serial Key for the given Windows XP version."
    echo "-t --tmpfs-size: Size, in gigabytes, to create a tmpfs for the "
    echo "    relevant VirtualBox files. It is advised to give it roughly"
    echo "    one gigabyte per VM and to have a few spare gigabytes "
    echo "    just in case."
    exit 1
}

while [ "$#" -gt 0 ]; do
    option="$1"
    shift

    case "$option" in
        -c|--vmcount)
            VMCOUNT="$1"
            shift
            ;;

        -i|--iso)
            ISOFILE="$1"
            shift
            ;;

        -s|--serial-key)
            SERIALKEY="$1"
            shift
            ;;

        -t|--tmpfs-size)
            TMPFSSIZE="$1"
            shift
            ;;

        *)
            echo "$0: Invalid argument.. $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "You'll probably want to run this script as root."
    exit 1
fi

# Update apt repository and install required packages.
apt-get update -y
apt-get install -y sudo git python-dev python-pip postgresql libpq-dev \
    python-dpkt vim tcpdump libcap2-bin genisoimage pwgen

# Install the most up-to-date version of VirtualBox available at the moment.
if [ ! -e "/usr/bin/VirtualBox" ]; then
    # Update our apt repository with "contrib".
    DEBVERSION="$(lsb_release -cs)"
    echo "deb http://download.virtualbox.org/virtualbox/debian " \
        "$DEBVERSION contrib" >> /etc/apt/sources.list

    # Add the VirtualBox public key to our apt repository.
    wget -q https://www.virtualbox.org/download/oracle_vbox.asc \
        -O- | apt-key add -

    # Install the most recent VirtualBox.
    apt-get update -y
    apt-get install -y virtualbox-4.3
fi

# Allow tcpdump to dump packet captures when executed as a normal user.
setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump

# Setup a Cuckoo user.
useradd cuckoo -d "/home/cuckoo/"

CUCKOO="/home/cuckoo/cuckoo/"
VMTEMP="$(mktemp -d "/home/cuckoo/XXXXXX")"

# Fetch Cuckoo.
git clone git://github.com/cuckoobox/cuckoo.git "$CUCKOO"

mkdir -p "$VMTEMP"

chown -R cuckoo:cuckoo "/home/cuckoo/" "$CUCKOO" "$VMTEMP"
chmod 755 "/home/cuckoo/" "$CUCKOO" "$VMTEMP"

# Install required packages part two.
pip install psycopg2 vmcloak -r "$CUCKOO/requirements.txt"

# Create a random password.
PASSWORD="$(pwgen -1 16)"

sql_query() {
    echo "$1"|sudo -u postgres psql
}

sql_query "DROP DATABASE cuckoo"
sql_query "CREATE DATABASE cuckoo"

sql_query "DROP USER cuckoo"
sql_query "CREATE USER cuckoo WITH PASSWORD '$PASSWORD'"

# Setup the VirtualBox hostonly network.
vmcloak-vboxnet0

# Run the magic iptables script that turns hostonly networks into full
# internet access.
vmcloak-iptables

MOUNT="/mnt/winxp/"

if [ ! -d "$MOUNT" ] || [ -z "$(ls -A "$MOUNT")" ]; then
    mkdir -p "$MOUNT"
    mount -o loop,ro "$ISOFILE" "$MOUNT"
fi

VMS="/home/cuckoo/vms/"
VMSBACKUP="/home/cuckoo/vms-backup/"
VMDATA="/home/cuckoo/vm-data/"

mkdir -p "$VMDATA"

# Setup tmpfs to store the various Virtual Machines.
if [ ! -d "$VMS" ]; then
    mkdir -p "$VMS"

    if [ "$TMPFSSIZE" -ne 0 ]; then
        mount -o "size=${TMPFSSIZE}G" -t tmpfs tmpfs "$VMS"
    fi
fi

chown cuckoo:cuckoo "$VMS" "$VMDATA"

VMCLOAKCONF="$(mktemp)"

cat > "$VMCLOAKCONF" <<EOF
[vmcloak]
cuckoo = $CUCKOO
vm-dir = $VMS
data-dir = $VMDATA
iso-mount = $MOUNT
serial-key = $SERIALKEY
dependencies = dotnet40 acrobat9
temp-dirpath = $VMTEMP
EOF

chown cuckoo:cuckoo "$VMCLOAKCONF"

# Create the Virtual Machine bird.
vmcloak -u cuckoo -s "$VMCLOAKCONF" --bird bird0

# Create various Virtual Machine eggs.
for i in $(seq -w 1 "$VMCOUNT"); do
    vmcloak-clone -u cuckoo --bird bird0 \
        --hostonly-ip "192.168.56.1$i" "egg$i"
done

rm -rf "$VMCLOAKCONF" "$VMTEMP"

# We create a backup of the Virtual Machines in case tmpfs is being used.
# Because if the machine for some reason does a reboot, all the contents of
# the tmpfs directory will be gone.
if [ "$TMPFSSIZE" -ne 0 ]; then
    sudo -u cuckoo -i cp -r "$VMS" "$VMSBACKUP"
fi

# Add "nmi_watchdog=0" to the GRUB commandline and recreate
# the GRUB configuration.
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT " \
    "nmi_watchdog=0\"" >> /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

echo "PostgreSQL connection string:  " \
    "postgresql://cuckoo:$PASSWORD@localhost/cuckoo"
