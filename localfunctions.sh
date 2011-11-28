
fatal() {
    echo $1
    exit 1
}

_create_global() {
cat << _EOF_
global_defs {
    notification_email {
        @NOTIFICATIONS@
    }
    notification_email_from @NOTIFICATIONS@
    router_id @ROUTERID@
}
_EOF_
}

_create_pool() {
    uuid=$1
    VHOST=$2

    RSP_HC=$(coreval Keepalived Keepalived:RSPool ${uuid} rsp_healthcheck)
    if [ "${RSP_HC}" = "HTTP_GET" -o "${RSP_HC}" = "SSL_GET" ]; then
        RSP_HC_URL=$(coreval Keepalived Keepalived:RSPool ${uuid} rsp_hc_url)
        RSP_HC_CODE=$(coreval Keepalived Keepalived:RSPool ${uuid} rsp_hc_retcode)
    elif [ "${RSP_HC}" = "TCP_CHECK" ]; then
        RSP_HC_PORT=$(coreval Keepalived Keepalived:RSPool ${uuid} rsp_hc_tcp_port)
    fi

    for rsuuid in `coreval --loop Keepalived Keepalived:RSPool ${uuid} Keepalived:Realserver`; do
        RS_IP=$(coreval Keepalived Keepalived:RSPool ${uuid} Keepalived:Realserver ${rsuuid} rs_ip)
        RS_PORT=$(coreval Keepalived Keepalived:RSPool ${uuid} Keepalived:Realserver ${rsuuid} rs_port)
        RS_WEIGHT=$(coreval Keepalived Keepalived:RSPool ${uuid} Keepalived:Realserver ${rsuuid} rs_weight)

        echo ${RS_IP} | grep -q : && RS_TYPE="v6" || RS_TYPE="v4"

        [ "${RS_TYPE}" != "${VIP_TYPE}" ] && fatal "mix46"
        [ "X${RS_WEIGHT}" = "X" ] && RS_WEIGHT=1

        if [ "${RSP_HC}" = "HTTP_GET" -o "${RSP_HC}" = "SSL_GET" ]; then
            GH_ARGS=""
            [ "${RSP_HC}" = "SSL_GET" ] && GH_ARGS="${GH_ARGS} --use-ssl"
            [ "X${VHOST}" != "X" ]      && GH_ARGS="${GH_ARGS} --use-virtualhost ${VHOST}"

            GH_ARGS="${GH_ARGS} --port ${RS_PORT}"
            GH_ARGS="${GH_ARGS} --url ${RSP_HC_URL}"
            GH_ARGS="${GH_ARGS} --server ${RS_IP}"

            RSP_HC_URLDIGEST=$(/usr/bin/genhash ${GH_ARGS} | awk ' { print $3 } ')
            [ "X${RSP_HC_URLDIGEST}" = "X" ] && fatal "nohash"
        fi
        cat << _EOF_
    real_server ${RS_IP} ${RS_PORT} {
        weight ${RS_WEIGHT}
_EOF_

        if [ "${RSP_HC}" = "HTTP_GET" -o "${RSP_HC}" = "SSL_GET" ]; then
            cat <<_EOF_
        ${RSP_HC} {
            url {
                path ${RSP_HC_URL}
                digest ${RSP_HC_URLDIGEST}
            }
            connect_port ${RS_PORT}
            connect_timeout 3
            nb_get_retry 3
            delay_before_retry 3
        }
_EOF_
        elif [ "${RSP_HC}" = "TCP_CHECK" ]; then
            cat <<_EOF_
        ${RSP_HC} {
            connect_port ${RSP_HC_PORT}
            connect_timeout 3
        }
_EOF_
        elif [ "${RSP_HC}" = "SMTP_CHECK" ]; then
            cat <<_EOF_
        ${RSP_HC} {
            host {
                connect_ip ${RS_IP}
                connect_port ${RS_PORT}
            }
            connect_timeout 3
            retry 3
            delay_before_retry 2
        }
_EOF_
        fi
        cat << _EOF_
    }
_EOF_
    
    done
}

_create_vip() {
    RSP_UUID=$1
    VIP_UUID=$2

    VIP_IP=$(coreval    Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_ip)
    VIP_PORT=$(coreval  Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_port)
    VIP_VHOST=$(coreval Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_vhost)
    VIP_ALG=$(coreval   Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_alg)
    cat <<_EOF_
virtual_server ${VIP_IP} ${VIP_PORT} {
    delay_loop 30
    lb_algo ${VIP_ALG}
    lb_kind NAT
    persistence_timeout 50
    protocol TCP
    persistence_granularity 32
    virtualhost ${VIP_VHOST}
    alpha
_EOF_
}

_get_vip_vhost() {
    RSP_UUID=$1
    VIP_UUID=$2

    VIP_VHOST=$(coreval Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_vhost)

    echo "${VIP_VHOST}"
}

_create_vip_static() {
    RSP_UUID=$1
    VIP_UUID=$2

    VIP_IP=$(coreval    Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_ip)

    [ -f /etc/openpanel/networking.def ] || fatal "Could not determine if ${VIP_IP} is present. Is Networking.module installed?"

    egrep -q "^addr.*\t${VIP_IP}\t.*" /etc/openpanel/networking.def  || echo ${VIP_IP}
}

_create_vip_vrrp() {
    RSP_UUID=$1
    VIP_UUID=$2

    VIP_IP=$(coreval    Keepalived Keepalived:RSPool ${RSP_UUID} Keepalived:SLBMaster ${VIP_UUID} vip_ip)

    [ -f /etc/openpanel/networking.def ] || fatal "Could not determine if ${VIP_IP} is present. Is Networking.module installed?"

    egrep -q "^addr.*\t${VIP_IP}\t.*" /etc/openpanel/networking.def  && fatal "VRRP can not be configured if ${VIP_IP} is actively configured on one of your interfaces"
    egrep -q "^addr.*\t${VIP_IP}\t.*" /etc/openpanel/networking.def  || echo ${VIP_IP}
}

function _create_statics() {
    STATICS=$(_uniq "$1")

    RET=""
    INTF=$(egrep ^iface /etc/openpanel/networking.def| awk ' { print $3 } ' | egrep -v '\tlo\t' | head -1 | tail -1)

    [ "X${INTF}" = "X" ] && fatal "noint"

    for s in ${STATICS}; do
        SUFFIX="/32"
        echo $s | grep -q : && SUFFIX="/128"
        RET="${RET}\t${s}${SUFFIX} dev ${INTF}\n"
    done
    
    if [ "X${RET}" != "X" ]; then
        cat <<_EOF_
static_ipaddress
{
    ${RET}
}
_EOF_
    fi
}

function _create_vrrp() {
    STATICS=$(_uniq "$1")

    RET=""

    VRRP_PASS=$(hostname -f | md5sum | awk ' { print $1 } ')
    VRID=$(echo ${VRRP_PASS} | tr '[a-z]' ' ' | sed -e 's/ //g' | cut -c1-2)

    for s in ${STATICS}; do
        SUFFIX="/32"
        echo $s | grep -q : && SUFFIX="/128"
        RET="${RET}\t${s}${SUFFIX} dev @EXTINTF@\n"
    done
    
    if [ "X${RET}" != "X" ]; then
        cat <<_EOF_
vrrp_sync_group VG_1 {
    group {
        loadbalanced_vrrp
    }
    smtp_alert
}
vrrp_instance loadbalanced_vrrp {
    state BACKUP
    interface @EXTINTF@
    dont_track_primary
    lvs_sync_daemon_interface @SYNCINTF@
    garp_master_delay 10
    virtual_router_id ${VRID}
    priority @PRIO@
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS}
    }
    virtual_ipaddress {
        ${RET}
    }
    preempt_delay 60
    smtp_alert
}

_EOF_
    fi
}

function _uniq() {
    STRING="$1"

    echo "${STRING}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}
