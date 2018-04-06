#!/usr/bin/env bash
set -e

echomsg "Generating passwords for the Message Broker"

mkdir -p ${PRIVATE}/cega/mq

function rabbitmq_hash {
    # 1) Generate a random 32 bit salt
    # 2) Concatenate that with the UTF-8 representation of the password
    # 3) Take the SHA-256 hash
    # 4) Concatenate the salt again
    # 5) Convert to base64 encoding
    local SALT=${2:-$(${OPENSSL:-openssl} rand -hex 4)}
    {
	printf ${SALT} | xxd -p -r
	( printf ${SALT} | xxd -p -r; printf $1 ) | ${OPENSSL:-openssl} dgst -binary -sha256
    } | base64
}


function join_by { local IFS="$1"; shift; echo -n "$*"; }

function output_password_hashes {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do 
	CEGA_MQ_PASSWORD=$(awk -F= '/CEGA_MQ_PASSWORD/{print $2}' ${PRIVATE}/${INSTANCE}/.trace)
	CEGA_MQ_HASH=$(rabbitmq_hash $CEGA_MQ_PASSWORD)
	tmp+=("{\"name\":\"cega_${INSTANCE}\",\"password_hash\":\"${CEGA_MQ_HASH}\",\"hashing_algorithm\":\"rabbit_password_hashing_sha256\",\"tags\":\"administrator\"}")
    done
    join_by ",\n" "${tmp[@]}"
}

function output_vhosts {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do 
	tmp+=("{\"name\":\"${INSTANCE}\"}")
    done
    join_by "," "${tmp[@]}"
}

function output_permissions {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do 
	tmp+=("{\"user\":\"cega_${INSTANCE}\", \"vhost\":\"${INSTANCE}\", \"configure\":\".*\", \"write\":\".*\", \"read\":\".*\"}")
    done
    join_by $',\n' "${tmp[@]}"
}

function output_queues {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do
	tmp+=("{\"name\":\"inbox\",     \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"inbox.checksums\", \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"files\",     \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"completed\", \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
	tmp+=("{\"name\":\"errors\",    \"vhost\":\"${INSTANCE}\", \"durable\":true, \"auto_delete\":false, \"arguments\":{}}")
    done
    join_by $',\n' "${tmp[@]}"
}

function output_exchanges {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do
	tmp+=("{\"name\":\"localega.v1\", \"vhost\":\"${INSTANCE}\", \"type\":\"topic\", \"durable\":true, \"auto_delete\":false, \"internal\":false, \"arguments\":{}}")
    done
    join_by $',\n' "${tmp[@]}"
}


function output_bindings {
    declare -a tmp
    for INSTANCE in ${INSTANCES}
    do
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"inbox\",\"routing_key\":\"files.inbox\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"inbox.checksums\",\"routing_key\":\"files.inbox.checksums\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"files\",\"routing_key\":\"files\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"completed\",\"routing_key\":\"files.completed\"}")
	tmp+=("{\"source\":\"localega.v1\",\"vhost\":\"${INSTANCE}\",\"destination_type\":\"queue\",\"arguments\":{},\"destination\":\"errors\",\"routing_key\":\"files.error\"}")
    done
    join_by $',\n' "${tmp[@]}"
}

cat > ${PRIVATE}/cega/mq/defs.json <<EOF
{"rabbit_version":"3.6.11",
 "users":[$(output_password_hashes)],
 "vhosts":[$(output_vhosts)],
 "permissions":[$(output_permissions)],
 "parameters":[],
 "global_parameters":[{"name":"cluster_name", "value":"rabbit@localhost"}],
 "policies":[],
 "queues":[$(output_queues)],
 "exchanges":[$(output_exchanges)],
 "bindings":[$(output_bindings)]
}
EOF

cat > ${PRIVATE}/cega/mq/rabbitmq.config <<EOF
%% -*- mode: erlang -*-
%%
[{rabbit,[{loopback_users, [ ] },
	  {disk_free_limit, "1GB"}]},
 {rabbitmq_management, [ {load_definitions, "/etc/rabbitmq/defs.json"} ]}
].
EOF