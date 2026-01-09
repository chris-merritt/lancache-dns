#!/usr/local/bin/bash
basedir="/root/lancache"
outputdir="${basedir}/unbound"
finaldir="/var/unbound"
path="${basedir}/cache_domains.json"
repo="https://raw.githubusercontent.com/uklans/cache-domains/refs/heads/master"

export IFS=" "

echo "Downloading cache_domains.json"
/usr/local/bin/curl -s "${repo}/cache_domains.json" > "${path}"

if ! command -v jq >/dev/null; then
	cat <<-EOF
		This script requires jq to be installed.
		Your package manager should be able to find it
	EOF
	exit 1
fi

combinedoutput=$(jq -r ".combined_output" config.json)

while read -r line; do
	ip=$(jq ".ips[\"${line}\"]" config.json)
	declare "cacheip${line}"="${ip}"
done <<<"$(jq -r ".ips | to_entries[] | .key" config.json)"

while read -r line; do
	name=$(jq -r ".cache_domains[\"${line}\"]" config.json)
	declare "cachename${line}"="${name}"
done <<<"$(jq -r ".cache_domains | to_entries[] | .key" config.json)"

mkdir -p ${outputdir}
mkdir -p ${finaldir}
while read -r entry; do
	unset cacheip
	unset cachename
	key=$(jq -r ".cache_domains[${entry}].name" ${path})
	cachename="cachename${key}"
	if [ -z "${!cachename}" ]; then
		continue
	fi
	if [[ ${cachename} == "disabled" ]]; then
		continue
	fi
	cacheipname="cacheip${!cachename}"
	cacheip=$(jq -r "if type == \"array\" then .[] else . end" <<<"${!cacheipname}" | xargs)
	while read -r fileid; do
		while read -r filename; do
			downloadfile="${repo}/${filename}"
			echo "Downloading ${filename}"
			/usr/local/bin/curl -s "${downloadfile}" > "${basedir}/${filename}" 
			destfilename=${filename//txt/conf}
			outputfile=${outputdir}/${destfilename}
			touch "${outputfile}"
			while read -r fileentry; do
				# Ignore comments and newlines
				if [[ ${fileentry} == \#* ]] || [[ -z ${fileentry} ]]; then
					continue
				fi
				parsed="${fileentry#\*\.}"
				if grep -qx "  local-zone: \"${parsed}\" redirect" "${outputfile}"; then
					continue
				fi
				if [[ $(head -n 1 "${outputfile}") != "server:" ]]; then
					echo "server:" >>"${outputfile}"
				fi
				echo "  local-zone: \"${parsed}\" redirect" >>"${outputfile}"
				for i in ${cacheip}; do
					echo "  local-data: \"${parsed} 30 IN A ${i}\"" >>"${outputfile}"
				done
			done <<<"$(cat ${basedir}/"${filename}" | sort)"
		done <<<"$(jq -r ".cache_domains[${entry}].domain_files[${fileid}]" ${path})"
	done <<<"$(jq -r ".cache_domains[${entry}].domain_files | to_entries[] | .key" ${path})"
done <<<"$(jq -r ".cache_domains | to_entries[] | .key" ${path})"

if [[ ${combinedoutput} == "true" ]]; then
	for file in "${outputdir}"/*; do f=${file//${outputdir}\//} && f=${f//.conf/} && echo "# ${f^}" >>${outputdir}/lancache.conf && cat "${file}" >>${outputdir}/lancache.conf && rm "${file}"; done
	mv "${outputdir}/lancache.conf" "${basedir}/lancache.conf"
	cp "${basedir}/lancache.conf" "${finaldir}/lancache.conf"
fi

cat <<EOF
Configuration generation completed.

Restarting Unbound.....
EOF

/usr/bin/su -m unbound -c '/usr/local/sbin/unbound-control -c /var/unbound/unbound.conf reload'
