#!/bin/bash

if [ "x$PGUSER"     != "x" ]; then
    POSTGRES_USER=$PGUSER
fi
if [ "x$PGPASSWORD" != "x" ]; then
    POSTGRES_PASSWORD=$PGPASSWORD
fi

if [ "x$PGPASSWORD" = "x" ]; then
    export PGPASSWORD=$POSTGRES_PASSWORD
fi


set -e

if [ "${1:0:1}" = '-' ]; then
	set -- postgres "$@"
fi

if [ "$1" = 'postgres' ]; then
	mkdir -p "$PGDATA"
	chmod 700 "$PGDATA"
	chown -R postgres "$PGDATA"

	mkdir -p /run/postgresql
	chmod g+s /run/postgresql
	chown -R postgres /run/postgresql

	if [ ! -s "$PGDATA/PG_VERSION" ]; then
	    if [ "x$REPLICATE_FROM" == "x" ]; then
		eval "gosu postgres initdb $POSTGRES_INITDB_ARGS"
	    else
            	until ping -c 1 -W 1 ${REPLICATE_FROM}
            	do
                	echo "Waiting for master to ping..."
                	sleep 1s
            	done
            	until gosu postgres pg_basebackup -h ${REPLICATE_FROM} -D ${PGDATA} -U ${POSTGRES_USER} -vP -w
            	do
                	echo "Waiting for master to connect..."
                	sleep 1s
            	done
	    fi

		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.
				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		if [ "x$REPLICATE_FROM" == "x" ]; then

		{ echo; echo "host replication all 0.0.0.0/0 $authMethod"; } | gosu postgres tee -a "$PGDATA/pg_hba.conf" > /dev/null
		{ echo; echo "host all all 0.0.0.0/0 $authMethod"; } | gosu postgres tee -a "$PGDATA/pg_hba.conf" > /dev/null

		gosu postgres pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses='localhost'" \
			-w start

		: ${POSTGRES_USER:=postgres}
		: ${POSTGRES_DB:=$POSTGRES_USER}
		export POSTGRES_USER POSTGRES_DB

		psql=( psql -v ON_ERROR_STOP=1 )

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			"${psql[@]}" --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi
		"${psql[@]}" --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
		EOSQL
		echo
		
		fi

		psql+=( --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" )

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${psql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

	if [ "x$REPLICATE_FROM" == "x" ]; then
		gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop
	fi

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi

	exec gosu postgres "$@"
fi

exec "$@"