#!/bin/bash
echo [TIMING `date +"%F %R:%S"`] Container starting

# TODO: if not in AWS, use "local"
AMAZON_CURRENT_AZ=$(wget -q -O - http://instance-data/latest/meta-data/placement/availability-zone)
export AMAZON_CURRENT_AZ=${AMAZON_CURRENT_AZ:-local}

echo [TIMING `date +"%F %R:%S"`] Current AZ is ${AMAZON_CURRENT_AZ}

term_handler() {
  /etc/init.d/nginx stop || true
  exit 0
}

trap 'term_handler' SIGTERM SIGKILL

if [ "$PACKAGE_NAME" != "" ]
then
    echo "ERROR: environment variable PACKAGE_NAME not set"
    echo "(hint: as in repo_name/PACKAGE_NAME, adjacent to setup.py, where the code is)"
    /etc/init.d/nginx stop || true
    exit 0
fi

# Activate virtualenv
cd /app
. ./.venv/bin/activate

# We may have a list of tasks, separated by colons
# For each task, we expect a management command
if [ "${COMPONENT_NAME}" == "TASK" ]; then
    # Run one off tasks, each separated by ";"
    if [ -n "${TASK_LIST}" ]; then
        IFS=';' read -ra CMDS <<< "${TASK_LIST}"
        for CMD in "${CMDS[@]}"; do
            echo [TIMING `date +"%F %R:%S"`] Starting task \"python manage.py ${CMD}\"
            python manage.py ${CMD}
            RESULT=$?
            if [ "${RESULT}" -ne 0 ]; then
                exit ${RESULT}
            fi
        done
    fi
    echo [TIMING `date +"%F %R:%S"`] Tasks completed
    exit 0
fi


# python manage.py createcachetable
# echo [TIMING `date +"%F %R:%S"`] Running collectstatic
# python manage.py collectstatic -i babel* -i webpac* -i uglify* -i sha* -i src -i crypto-browserify -i core-js -i docs -i media --noinput > /tmp/collectstatic_log || cat /tmp/collectstatic_log

# # check if database empty (no fixtures loaded, DB just created)
# export PGPASSWORD="$APP_DB_PASSWORD"
# # TODO: it still returns " 0" instead of 0?
# count=`psql -d $APP_DB_NAME -w -p $APP_DB_PORT -U $APP_DB_USERNAME -h $APP_DB_HOST -c "SELECT count(*) FROM post_office_emailtemplate;" |head -3|tail -1|sed -e 's/ //g'`
#
# if [ "$count" == "0" ]; then
#     # start this only if database is empty
#     python manage.py loaddata $PACKAGE_NAME/fixtures/base/*.json
# fi

# hotfix to provide media files accessible for stage and prod
ln -s /app/media/ /app/$PACKAGE_NAME/static/images/media
#

echo [TIMING `date +"%F %R:%S"`] Going to the component
case $COMPONENT_NAME in
WEB)
    # run flower in background
    if [[  ${FLOWER_BASIC_AUTH} ]]
    then
        echo [TIMING `date +"%F %R:%S"`] Starting flower
        celery --app=$PACKAGE_NAME.celery_app.app flower --basic_auth="${FLOWER_BASIC_AUTH}" --url_prefix=celery/flower --address=0.0.0.0 &  
    else
        echo "Skipping flower startup due to lack credentials variable"
    fi

    echo [TIMING `date +"%F %R:%S"`] Starting nginx
    /etc/init.d/nginx start

    # run main worker in current thread
    echo [TIMING `date +"%F %R:%S"`] Starting www workers
    gunicorn $PACKAGE_NAME.wsgi:application --bind 0.0.0.0:8000 --workers ${APP_WORKER_COUNT} --log-level=info --reload --daemon --timeout 600 --max-requests=100 --max-requests-jitter=50
;;
WORKER)
# TODO: daemon
# TODO: logrotate and stuff
    export DJANGO_SETTINGS_MODULE=$PACKAGE_NAME.settings
    export C_FORCE_ROOT='true'
    # try run beat in backround for every worker, only one will be started
    echo [TIMING `date +"%F %R:%S"`] Starting celery beat
    single-beat celery --app=$PACKAGE_NAME.celery_app.app beat &
    echo [TIMING `date +"%F %R:%S"`] Starting celery workers
    celery --app=$PACKAGE_NAME.celery_app.app worker --concurrency=4 -n celery@`hostname`.${AMAZON_CURRENT_AZ}
;;
*)
# TODO: remove code duplication
    echo [TIMING `date +"%F %R:%S"`] Starting nginx wrong way
    /etc/init.d/nginx start
    echo [TIMING `date +"%F %R:%S"`] Starting gunicorn wrong way
    gunicorn $PACKAGE_NAME.wsgi:application --bind 0.0.0.0:8000 --workers ${APP_WORKER_COUNT} --log-level=info --reload --daemon --timeout 600 --max-requests=100 --max-requests-jitter=50
;;
esac

echo [TIMING `date +"%F %R:%S"`] Exec "$@"
# exec "$@" &

echo [TIMING `date +"%F %R:%S"`] Entering terminate wait loop
while true
do
  tail -f /dev/null & wait ${!}
done
