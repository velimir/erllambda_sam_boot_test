#!/usr/bin/env bash

set -e
set -o pipefail

function usage {

	cat <<EOM
Usage: $(basename "$0") STACK_NAME LOG_STREAM_ARN CODE_LOADING_MODE ARTIFACTS_BUCKET GEN_COUNT

Repeatedly deploy, invoke lambda function and destroy stack to generate stats

EOM

	exit 2
}

for i in `seq 1 5`; do
    if [[ -z ${!i} ]] ; then
        usage
    fi
done

STACK_NAME=$1        ; shift
LOG_STREAM_ARN=$1    ; shift
CODE_LOADING_MODE=$1 ; shift
ARTIFACTS_BUCKET=$1  ; shift
GEN_COUNT=$1         ; shift


function lambda_name {
    STACK_DESCRIPTION=$1
    KEY=$2
    QUERY=".[] | select(.OutputKey == \"$KEY\") | .OutputValue"
    echo "$STACK_DESCRIPTION" | jq -r "$QUERY"
}

function package_stack {
    BUCKET=$1
    aws cloudformation package               \
        --template-file etc/template.yaml    \
        --output-template-file packaged.yaml \
        --s3-bucket $BUCKET
}

function deploy_stack {
    STACK_NAME=$1
    LOG_STREAM_ARN=$2
    CODE_LOADING_MODE=$3

    aws cloudformation deploy            \
        --template-file packaged.yaml    \
        --stack-name $STACK_NAME         \
        --capabilities CAPABILITY_IAM    \
        --parameter-overrides            \
            LogStreamARN=$LOG_STREAM_ARN \
            CodeLoadingMode=$CODE_LOADING_MODE
}

function describe_stack {
    STACK_NAME=$1
    aws cloudformation describe-stacks --stack-name $STACK_NAME
}

function stack_exists {
    STACK_NAME=$1
    describe_stack $STACK_NAME > /dev/null 2>&1
}

function stack_outputs {
    STACK_NAME=$1
    describe_stack $STACK_NAME | jq -c '.Stacks[].Outputs'
}

function delete_stack {
    STACK_NAME=$1
    aws cloudformation delete-stack --stack-name $STACK_NAME
    while `stack_exists $STACK_NAME` ; do
        echo "Waiting for stack to be deleted..."
        sleep 5
    done
    echo "Stack deleted"
}

function lambda_invoke {
    STACK_OUTPUTS=$1
    LAMBDA_KEY=$2
    OUTPUT_FILE=$3
    aws lambda invoke                                              \
        --function-name `lambda_name "$STACK_OUTPUTS" $LAMBDA_KEY` \
        --region us-east-1                                         \
        --log-type None                                            \
        --payload ''                                               \
        $OUTPUT_FILE
}

function gen_stats {
    STACK_NAME=$1
    LOG_STREAM_ARN=$2
    CODE_LOADING_MODE=$3
    GEN_COUNT=$4

    for i in `seq 1 $GEN_COUNT`; do
        deploy_stack $STACK_NAME $LOG_STREAM_ARN $CODE_LOADING_MODE
        STACK_OUTPUTS=`stack_outputs $STACK_NAME`
        # call several times to get boot time and execution time
        echo "Poking lambda function..."
        for j in `seq 1 10`; do
            lambda_invoke "$STACK_OUTPUTS" BootTestFunction /dev/null > /dev/null 2>&1
        done

        # sleep to make sure all log items where processes by stats function
        echo "Waiting until log stream is processed..."
        sleep 30
        # delete stack to get boot time stats
        echo "Deleting stack..."
        delete_stack $STACK_NAME
        sleep 30
    done
}

package_stack $ARTIFACTS_BUCKET
gen_stats $STACK_NAME $LOG_STREAM_ARN $CODE_LOADING_MODE $GEN_COUNT
