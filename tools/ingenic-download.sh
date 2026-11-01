#!/bin/bash
# Source this file, then capture ingenic_archive's verified absolute path.
# Explicit archive overrides never fall back to the cache or the network.
ingenic_archive() (
	local variable=$1 cache=$2 filename=$3 hash_tool=$4 digest=$5 url=$6
	local archive part
	case "$hash_tool" in
		md5sum|sha256sum) ;;
		*) echo "ingenic: unsupported checksum tool: $hash_tool" >&2; return 1 ;;
	esac
	if [[ -v $variable ]]; then
		archive=${!variable}
		if [ ! -f "$archive" ]; then
			echo "ingenic: $variable archive not found: $archive" >&2
			return 1
		fi
	else
		archive=$cache/$filename
		if [ ! -f "$archive" ]; then
			mkdir -p "$cache" || return 1
			part=$archive.part
			trap 'rm -f -- "$part"' EXIT
			echo "ingenic: downloading $filename" >&2
			curl -fsS --retry 5 -C - \
				--user "${INGENIC_FTP_USER:-ingenic_public}:${INGENIC_FTP_PASS:-BFdg2f9B12}" \
				-o "$part" "$url" >&2 || return 1
			if ! printf '%s  %s\n' "$digest" "$part" | "$hash_tool" -c --status; then
				echo "ingenic: $hash_tool mismatch for $part" >&2
				return 1
			fi
			mv -- "$part" "$archive" || return 1
			trap - EXIT
			archive=$(realpath -- "$archive") || return 1
			printf '%s\n' "$archive"
			return
		fi
	fi
	echo "ingenic: verifying $archive ($hash_tool)" >&2
	if ! printf '%s  %s\n' "$digest" "$archive" | "$hash_tool" -c --status; then
		echo "ingenic: $hash_tool mismatch for $archive" >&2
		return 1
	fi
	archive=$(realpath -- "$archive") || return 1
	printf '%s\n' "$archive"
)
