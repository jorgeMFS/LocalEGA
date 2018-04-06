#!/usr/bin/env bash
set -e

[ ${BASH_VERSINFO[0]} -lt 4 ] && echo 'Bash 4 (or higher) is required' 1>&2 && exit 1

HERE=$(dirname ${BASH_SOURCE[0]})
PRIVATE=${HERE}/private

# Defaults
VERBOSE=no
FORCE=yes
OPENSSL=openssl

function usage {
    echo "Usage: $0 [options] <instance> <instance>..."
    echo -e "\nOptions are:"
    echo -e "\t--openssl <value>   \tPath to the Openssl executable [Default: ${OPENSSL}]"
    echo ""
    echo -e "\t--verbose, -v       \tShow verbose output"
    echo -e "\t--polite, -p        \tDo not force the re-creation of the subfolders. Ask instead"
    echo -e "\t--help, -h          \tOutputs this message and exits"
    echo ""
}

# While there are arguments or '--' is reached
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0;;
        --verbose|-v) VERBOSE=yes;;
        --polite|-p) FORCE=no;;
        --openssl) OPENSSL=$2; shift;;
        *) break;;
    esac
    shift
done

# The rest of the parameters are the instances
INSTANCES=($@)

[[ $VERBOSE == 'no' ]] && echo -en "Bootstrapping "

source ${HERE}/../bootstrap/defs.sh

rm_politely ${PRIVATE} ${FORCE}
mkdir -p ${PRIVATE}/{users,certs}

exec 2>${PRIVATE}/.err

##############################################################
# Central EGA Users
##############################################################

echomsg "Generating fake Central EGA users"

[[ -x $(readlink ${OPENSSL}) ]] && echo "${OPENSSL} is not executable. Adjust the setting with --openssl" && exit 3

EGA_USER_PASSWORD_JOHN=$(generate_password 16)
EGA_USER_PASSWORD_JANE=$(generate_password 16)
EGA_USER_PASSWORD_TAYLOR=$(generate_password 16)

EGA_USER_PUBKEY_JOHN=${PRIVATE}/users/john.pub
EGA_USER_SECKEY_JOHN=${PRIVATE}/users/john.sec

EGA_USER_PUBKEY_JANE=${PRIVATE}/users/jane.pub
EGA_USER_SECKEY_JANE=${PRIVATE}/users/jane.sec

${OPENSSL} genrsa -out ${EGA_USER_SECKEY_JOHN} -passout pass:${EGA_USER_PASSWORD_JOHN} 2048
${OPENSSL} rsa -in ${EGA_USER_SECKEY_JOHN} -passin pass:${EGA_USER_PASSWORD_JOHN} -pubout -out ${EGA_USER_PUBKEY_JOHN}
chmod 400 ${EGA_USER_SECKEY_JOHN}

${OPENSSL} genrsa -out ${EGA_USER_SECKEY_JANE} -passout pass:${EGA_USER_PASSWORD_JANE} 2048
${OPENSSL} rsa -in ${EGA_USER_SECKEY_JANE} -passin pass:${EGA_USER_PASSWORD_JANE} -pubout -out ${EGA_USER_PUBKEY_JANE}
chmod 400 ${EGA_USER_SECKEY_JANE}

cat > ${PRIVATE}/users/john.yml <<EOF
---
password_hash: $(${OPENSSL} passwd -1 ${EGA_USER_PASSWORD_JOHN})
pubkey: $(ssh-keygen -i -mPKCS8 -f ${EGA_USER_PUBKEY_JOHN})
EOF

cat > ${PRIVATE}/users/jane.yml <<EOF
---
pubkey: $(ssh-keygen -i -mPKCS8 -f ${EGA_USER_PUBKEY_JANE})
EOF

cat > ${PRIVATE}/users/taylor.yml <<EOF
---
password_hash: $(${OPENSSL} passwd -1 ${EGA_USER_PASSWORD_TAYLOR})
EOF

mkdir -p ${PRIVATE}/users/{swe1,fin1}
# They all have access to SWE1
( # In a subshell
    cd ${PRIVATE}/users/swe1
    ln -s ../john.yml .
    ln -s ../jane.yml .
    ln -s ../taylor.yml .
)
# John has also access to FIN1
(
    cd ${PRIVATE}/users/fin1
    ln -s ../john.yml .
)

echomsg "Generate SSL certificates for HTTPS"
${OPENSSL} req -x509 -newkey rsa:2048 -keyout ${PRIVATE}/cega.key -nodes -out ${PRIVATE}/cega.cert -sha256 -days 1000 -subj "/C=ES/ST=Catalunya/L=Barcelona/O=CEGA/OU=CEGA/CN=CentralEGA/emailAddress=central@ega.org"


cat > ${PRIVATE}/.trace <<EOF
#####################################################################
#
# Generated by cega/bootstrap.sh
#
#####################################################################
EGA_USER_PASSWORD_JOHN    = ${EGA_USER_PASSWORD_JOHN}
EGA_USER_PUBKEY_JOHN      = ./private/users/john.pub
EGA_USER_PUBKEY_JANE      = ./private/users/jane.pub
EGA_USER_PASSWORD_TAYLOR  = ${EGA_USER_PASSWORD_TAYLOR}
# =============================
EOF

# And the CEGA files
{
    echo -n "LEGA_INSTANCES="
    join_by ',' ${INSTANCES[@]}
    echo
} > ${PRIVATE}/env


##############################################################
# Generate the configuration for each instance
##############################################################

declare -A CEGA_MQ_PASSWORD=()
declare -A CEGA_REST_PASSWORD=()
for INSTANCE in ${INSTANCES[@]}
do
    CEGA_MQ_PASSWORD[${INSTANCE}]=$(generate_password 16)
    echo "CEGA_${INSTANCE}_MQ_PASSWORD   = ${CEGA_MQ_PASSWORD[${INSTANCE}]}" >> ${PRIVATE}/.trace
    CEGA_REST_PASSWORD[${INSTANCE}]=$(generate_password 16)
    echo "CEGA_${INSTANCE}_REST_PASSWORD = ${CEGA_REST_PASSWORD[${INSTANCE}]}" >> ${PRIVATE}/env
done

##############################################################
# Central EGA Message Broker
##############################################################

echomsg "Generating passwords for the Message Broker"

function output_vhosts {
    declare -a tmp=()
    tmp+=("{\"name\":\"/\"}")
    for INSTANCE in ${INSTANCES[@]}
    do 
	tmp+=("{\"name\":\"${INSTANCE}\"}")
    done
    join_by "," "${tmp[@]}"
}

function output_queues {
    declare -a tmp
    for INSTANCE in ${INSTANCES[@]}
    do
	tmp+=("{\"name\":\"inbox\",     \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"inbox.checksums\",     \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"files\",     \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"completed\", \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"errors\",    \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
    done
    join_by $',\n' "${tmp[@]}"
}

function output_exchanges {
    declare -a tmp=()
    for INSTANCE in ${INSTANCES[@]}
    do
	tmp+=("{\"name\":\"localega.v1\", \"vhost\":\"${INSTANCE}\", \"type\":\"topic\", \"durable\":true, \"auto_delete\":false, \"internal\":false, \"arguments\":{}}")
    done
    join_by $',\n' "${tmp[@]}"
}


function output_bindings {
    declare -a tmp
    for INSTANCE in ${INSTANCES[@]}
    do
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"inbox\",\"routing_key\":\"inbox\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"inbox.checksums\",\"routing_key\":\"inbox.checksums\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"files\",\"routing_key\":\"files\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"completed\",\"routing_key\":\"completed\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"errors\",\"routing_key\":\"errors\"}")
    done
    join_by $',\n' "${tmp[@]}"
}

{
    echo    '{"rabbit_version":"3.3.5",'
    echo    ' "users":[],'
    echo -n ' "vhosts":['; output_vhosts; echo '],'
    echo    ' "permissions":[],'
    echo    ' "parameters":[],'
    echo    ' "policies":[],'
    echo -n ' "queues":['; output_queues; echo '],'
    echo -n ' "exchanges":['; output_exchanges; echo '],'
    echo -n ' "bindings":['; output_bindings; echo ']'
    echo    '}'
} > ${PRIVATE}/defs.json

cat > ${PRIVATE}/mq_users.sh <<EOF
#!/usr/bin/env bash
set -e
EOF
for INSTANCE in ${INSTANCES[@]}
do
    {
	echo
	# Creating VHost
	#echo "rabbitmqctl add_vhost ${instance}"
	# Adding user
	echo "rabbitmqctl add_user cega_${INSTANCE} ${CEGA_MQ_PASSWORD[${INSTANCE}]}"
	echo "rabbitmqctl set_user_tags cega_${INSTANCE} administrator"
	# Setting permissions
	echo "rabbitmqctl set_permissions -p ${INSTANCE} cega_${INSTANCE} \".*\" \".*\" \".*\""
	echo
    } >> ${PRIVATE}/mq_users.sh
done


task_complete "Bootstrap complete"