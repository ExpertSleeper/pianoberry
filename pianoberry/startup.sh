#!/bin/sh

export HOME="/root"
export USER="root"
export XDG_CONFIG_HOME="/root/.config"
export XDG_DATA_HOME="/root/.local/share"

BOOT_DIR="/mnt/mmcblk0p1"
CONFIG_FILE="$BOOT_DIR/config.txt"
LOG_FILE="$BOOT_DIR/pianoberry.log"

mount "$BOOT_DIR" 2>/dev/null

# Set SSH password so ssh tc@<ip> works with password piCore
echo "tc:piCore" | chpasswd 2>/dev/null || true
echo "root:piCore" | chpasswd 2>/dev/null || true

# Import SSH public keys from SD card if present
if [ -f "$BOOT_DIR/authorized_keys" ]; then
	mkdir -p /home/tc/.ssh /root/.ssh
	cp "$BOOT_DIR/authorized_keys" /home/tc/.ssh/authorized_keys
	cp "$BOOT_DIR/authorized_keys" /root/.ssh/authorized_keys
	chmod 600 /home/tc/.ssh/authorized_keys /root/.ssh/authorized_keys
	chown -R tc:staff /home/tc/.ssh 2>/dev/null || true
fi

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	if [ -d "$BOOT_DIR" ]; then
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
	fi
}

log "=== Pianoberry startup starting ==="

read_config() {
	if [ -f "$CONFIG_FILE" ]; then
		while IFS= read -r line; do
			case "$line" in
				pianoteq_serial=*)
					PIANOTEQ_SERIAL="${line#*=}"
					;;
				pianoteq_initial_preset=*)
					PIANOTEQ_INITIAL_PRESET="${line#*=}"
					;;
			esac
		done < "$CONFIG_FILE"
	fi
}

read_config

# Check if the boot partition contains a Pianoteq binary (Stage, Pro, Standard, or versioned)
for bin in "$BOOT_DIR"/Pianoteq\ [89]*; do
	if [ -f "$bin" ]; then
		log "Found Pianoteq binary on boot partition: $(basename "$bin")"
		install -m 755 "$bin" /usr/bin/Pianoteq
		break
	fi
done

# Automatically derive required preferences filename from Pianoteq binary version
if [ -x "/usr/bin/Pianoteq" ]; then
	RAW_VER=$(/usr/bin/Pianoteq --version 2>&1 | head -n1)
	log "Pianoteq --version reported: '$RAW_VER'"

	VERSION_STR=$(echo "$RAW_VER" | grep -oE '[0-9]+\.[0-9]+' | head -n1)
	if [ -z "$VERSION_STR" ]; then
		VERSION_STR=$(strings /usr/bin/Pianoteq 2>/dev/null | grep -iE 'Pianoteq.*[0-9]+\.[0-9]+' | head -n1 | grep -oE '[0-9]+\.[0-9]+')
	fi

	mkdir -p "/root/.config/Modartt"

	# Pre-seed common version pref files (90 through 95) so any minor version finds valid config
	for tag in 90 91 92 93 94 95; do
		if [ ! -f "/root/.config/Modartt/Pianoteq${tag}.prefs" ] && [ -f "/usr/local/share/pianoberry/Pianoteq.prefs" ]; then
			cp "/usr/local/share/pianoberry/Pianoteq.prefs" "/root/.config/Modartt/Pianoteq${tag}.prefs"
		fi
	done

	if [ -n "$VERSION_STR" ]; then
		VER_TAG=$(echo "$VERSION_STR" | tr -d '.')
		TARGET_PREFS="/root/.config/Modartt/Pianoteq${VER_TAG}.prefs"
		log "Configuring preferences for detected version ($VERSION_STR): $TARGET_PREFS"

		if [ ! -f "$TARGET_PREFS" ]; then
			EXISTING_PREFS=$(ls -t /root/.config/Modartt/Pianoteq*.prefs 2>/dev/null | head -n1)
			if [ -n "$EXISTING_PREFS" ] && [ -f "$EXISTING_PREFS" ]; then
				cp "$EXISTING_PREFS" "$TARGET_PREFS"
			elif [ -f "/usr/local/share/pianoberry/Pianoteq.prefs" ]; then
				cp "/usr/local/share/pianoberry/Pianoteq.prefs" "$TARGET_PREFS"
			fi
		fi
	fi

	# Mirror to /tmp and /home/tc for any fallback path
	mkdir -p /tmp/.config/Modartt /home/tc/.config/Modartt
	cp -a /root/.config/Modartt/. /tmp/.config/Modartt/ 2>/dev/null || true
	cp -a /root/.config/Modartt/. /home/tc/.config/Modartt/ 2>/dev/null || true
fi

# License activation if needed
if [ ! -f "/opt/.activated" ]; then
	if /usr/bin/Pianoteq --help 2>&1 | grep -q activate; then
		log "Full Pianoteq version detected. Checking activation..."
		if [ -z "$PIANOTEQ_SERIAL" ]; then
			log "Warning: pianoteq_serial is empty in config.txt. Skipping activation."
		else
			log "Waiting for internet connection (timeout 30s)..."
			NET_OK=0
			for i in $(seq 1 30); do
				if ping -c1 -W1 www.google.com > /dev/null 2>&1; then
					NET_OK=1
					break
				fi
				sleep 1
			done

			if [ $NET_OK -eq 1 ]; then
				log "Network available. Activating Pianoteq license..."
				/usr/bin/Pianoteq --headless --activate "pianoberry:$PIANOTEQ_SERIAL"
				if [ $? -eq 0 ]; then
					log "Activation successful!"
					touch /opt/.activated
					grep -qxF "root" /opt/.filetool.lst 2>/dev/null || echo "root" >> /opt/.filetool.lst
					grep -qxF "usr/bin/Pianoteq" /opt/.filetool.lst 2>/dev/null || echo "usr/bin/Pianoteq" >> /opt/.filetool.lst
					filetool.sh -b

					# Mirror updated license and config
					mkdir -p /tmp/.config/Modartt /home/tc/.config/Modartt
					cp -a /root/.config/Modartt/. /tmp/.config/Modartt/ 2>/dev/null || true
					cp -a /root/.config/Modartt/. /home/tc/.config/Modartt/ 2>/dev/null || true
				else
					log "Error: Pianoteq activation failed."
				fi
			else
				log "Warning: Network timeout. Could not reach activation servers."
			fi
		fi
	fi
fi

# Create Pianoteq user presets folder if it doesn't exist
mkdir -p "/root/.local/share/Modartt/Pianoteq/Presets/My Presets/"

# Check if there are any .fxp files in the boot partition and copy them to the Pianoteq user presets folder
find "$BOOT_DIR" -maxdepth 1 -type f -name "*.fxp" 2>/dev/null | while read -r fxp_file; do
	filename=$(basename "$fxp_file")
	log "Importing preset: $filename"
	install -m 644 "$fxp_file" "/root/.local/share/Modartt/Pianoteq/Presets/My Presets/$filename"
done

# Ensure MIDI mapping folder exists and midi-map.ptm is installed
mkdir -p "/root/.local/share/Modartt/Pianoteq/MidiMappings/"
if [ -f "$BOOT_DIR/midi-map.ptm" ]; then
	log "Importing custom midi-map.ptm from boot partition"
	install -m 644 "$BOOT_DIR/midi-map.ptm" "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm"
elif [ ! -f "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm" ] && [ -f "/usr/local/share/pianoberry/midi-map.ptm" ]; then
	log "Installing default midi-map.ptm"
	install -m 644 /usr/local/share/pianoberry/midi-map.ptm "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm"
fi

# Mirror to /tmp and /home/tc
mkdir -p /tmp/.local/share/Modartt/Pianoteq/MidiMappings /home/tc/.local/share/Modartt/Pianoteq/MidiMappings
if [ -f "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm" ]; then
	cp -f "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm" /tmp/.local/share/Modartt/Pianoteq/MidiMappings/ 2>/dev/null || true
	cp -f "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm" /home/tc/.local/share/Modartt/Pianoteq/MidiMappings/ 2>/dev/null || true
fi

# Ensure default preset fallback
if [ -z "$PIANOTEQ_INITIAL_PRESET" ]; then
	PIANOTEQ_INITIAL_PRESET="NY Steinway D Player"
fi

# Unmute ALSA master volume if muted
amixer -c 0 sset Master unmute 100% >/dev/null 2>&1 || true

# Determine midimapping argument
MIDI_OPT=""
if [ -f "/root/.local/share/Modartt/Pianoteq/MidiMappings/midi-map.ptm" ]; then
	MIDI_OPT="--midimapping midi-map"
fi

# Ensure ALSA library does not trigger UMP buffer underflow on kernels without CONFIG_SND_SEQ_UMP
if [ -f /usr/local/lib/libasound.so.2.0.0 ]; then
	ORIG_HEX=$(od -A n -N 8 -j 703724 -t x1 /usr/local/lib/libasound.so.2.0.0 2>/dev/null | tr -d ' \n')
	if [ "$ORIG_HEX" = "fd7bb0a9fd030091" ]; then
		log "Applying ALSA UMP safety fix to libasound..."
		cp /usr/local/lib/libasound.so.2.0.0 /tmp/libasound.so.2.0.0
		printf '\x00\x00\x80\x52\xc0\x03\x5f\xd6' | dd of=/tmp/libasound.so.2.0.0 bs=1 seek=703724 conv=notrunc 2>/dev/null
		mount --bind /tmp/libasound.so.2.0.0 /usr/local/lib/libasound.so.2.0.0
	fi
fi

log "Starting Pianoteq with preset: '$PIANOTEQ_INITIAL_PRESET' $MIDI_OPT"
sync
umount "$BOOT_DIR" 2>/dev/null

exec /usr/bin/Pianoteq --headless --preset "$PIANOTEQ_INITIAL_PRESET" $MIDI_OPT
