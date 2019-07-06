#!/usr/bin/env bash

setUp() {
  echo "#!/usr/bin/env bash
echo foo
" > /tmp/aws ; chmod +x /tmp/aws
  echo "#!/usr/bin/env bash
echo bar
" > /tmp/curl ; chmod +x /tmp/curl

  . placebo
  PATH=/tmp:$PATH pill_attach "command=aws" "data_path=shunit2/fixtures"
}

tearDown() {
  rm -f \
    /tmp/aws \
    /tmp/curl \
    shunit2/fixtures/curl.sh \
    expected_content

  type -t pill_detach > /dev/null && pill_detach ; true
}

oneTimeTearDown() {
  git checkout shunit2/fixtures/aws.sh
}

testPlayback() {
  . placebo
  pill_attach "command=aws" "data_path=shunit2/fixtures"
  pill_playback
  response=$(aws autoscaling describe-auto-scaling-groups)
  assertEquals "response" "$response"
}

testRecord() {
  . placebo
  pill_attach "command=aws" "data_path=shunit2/fixtures"
  pill_record

  OLDPATH=$PATH
  PATH=/tmp:$PATH

  command_to_run="aws ec2 run-instances --image-id foo"
  $command_to_run > /dev/null
  cat > expected_content <<EOD
case "aws \$*" in
'aws autoscaling describe-auto-scaling-groups')
  cat <<'EOF'
response
EOF
  ;;
'$command_to_run') echo 'foo' ;;
*)
  echo "No responses for: aws \$*" | tee -a unknown_commands
  ;;
esac
EOD

  assertEquals "" "$(diff -wu expected_content "$DATA_PATH"/aws.sh)"
  # shellcheck disable=SC2086
  assertEquals "foo" "$(bash /tmp/$command_to_run)"
  assertEquals "$command_to_run" "$(pill_log)"

  PATH=$OLDPATH
}

testRecordShortCommand() {
  . placebo
  pill_attach "command=aws" "data_path=shunit2/fixtures"
  pill_record

  OLDPATH=$PATH
  PATH=/tmp:$PATH

  command_to_run="aws help"
  $command_to_run > /dev/null
  cat > expected_content <<EOD
case "aws \$*" in
'aws autoscaling describe-auto-scaling-groups')
  cat <<'EOF'
response
EOF
  ;;
'aws ec2 run-instances --image-id foo') echo 'foo' ;;
'$command_to_run') echo 'foo' ;;
*)
  echo "No responses for: aws \$*" | tee -a unknown_commands
  ;;
esac
EOD

  assertEquals "" "$(diff -wu expected_content "$DATA_PATH"/aws.sh)"

  PATH=$OLDPATH
}

testRecordMultipleCommands() {
  . placebo
  pill_attach "command=aws,curl" "data_path=shunit2/fixtures"
  pill_record

  OLDPATH=$PATH
  PATH=/tmp:$PATH

  command_to_run="curl https://foo/bar/baz"
  $command_to_run > /dev/null
  cat > expected_content <<EOD
case "curl \$*" in
'$command_to_run') echo 'bar' ;;
*)
  echo "No responses for: curl \$*" | tee -a unknown_commands
  ;;
esac
EOD

  assertEquals "command 1 is not curl but '${COMMANDS[1]}'" "curl" "${COMMANDS[1]}"
  assertEquals "" "$(diff -wu expected_content "$DATA_PATH"/curl.sh)"
  # shellcheck disable=SC2086
  assertEquals "bar" "$(bash /tmp/$command_to_run)"
  assertEquals "$command_to_run" "$(pill_log)"

  PATH=$OLDPATH
}

testNonexistentCommands() {
  . placebo
  response=$(pill_attach "command=aws,curl,foobarbaz" "data_path=shunit2/fixtures" | head -1)
  assertEquals \
    "command 'foobarbaz' not found" \
    "$response"
}

testDataPathIsNotADir() {
  . placebo
  response=$(pill_attach "command=aws" "data_path=shunit2/fixtures/aws.sh" | head -1)
  assertEquals \
    "DATA_PATH should be a directory" \
    "$response"
}

testPillNotSet() {
  . placebo
  response=$(aws ec2 run-instances)
  assertEquals \
    "PILL must be set to playback or record. Try pill_playback or pill_record" \
    "$response"
}

testDataPathNotSet() {
  . placebo
  pill_playback
  unset DATA_PATH # not sure why this line is required.
  response=$(aws ec2 run-instances)
  assertEquals \
    "DATA_PATH must be set. Try pill_attach" "$response"
}

testExecutePlacebo() {
  response=$(bash placebo)
  assertTrue "Usage message not seen" "grep -q Usage <<< $response"
}

testDetach() {
  funcs="_usage
pill_attach
pill_playback
pill_record
pill_log
pill_detach
_mock
_cli_to_comm
_comm_to_file
_create_new
_update_existing
_filter
_record"
  . placebo
  pill_detach
  for f in $funcs ; do
    assertFalse "function $f is still defined" "type $f"
  done
  assertTrue "[ -z $PILL ]"
  assertTrue "[ -z $DATA_PATH ]"
  assertFalse "[ -e commands_log ]"
  . placebo
}

testMainUsage() {
  response=$(. placebo -h)
  assertEquals "Usage: . shunit2/placebo.sh [-h]" "$response"
  . placebo
}

testPillFunctionUsage() {
  . placebo
  response=$(pill_playback -h)
  assertEquals "Usage: pill_playback [-h]
Sets Placebo to playback mode" "$response"
}

functionUnderTest1() {
  dir=/tmp/foo
  touch "$dir"
  response=$(ls -l "$dir")
  echo "$response"
  rm -f "$dir"
}

testEndToEnd() {
  response0="$(functionUnderTest1)"
  echo "response #0 - no placebo: $response0"

  . placebo
  pill_attach "command=touch,ls,rm" "data_path=shunit2/fixtures"
  pill_record
  response1="$(functionUnderTest1)"
  echo "response #1 - placebo record: $response1"
  pill_detach

  . placebo
  pill_attach "command=touch,ls,rm" "data_path=shunit2/fixtures"
  pill_playback
  response2="$(functionUnderTest1)"
  echo "response #2 - placebo playback: $response2"
  pill_detach
  assertEquals "end to end test returned different response in playback mode" "$response0" "$response1"
  assertEquals "end to end test returned different response in playback mode" "$response1" "$response2"

  command rm -f shunit2/fixtures/{touch,ls,rm}.sh
}

testExitStatusIsPreserved() {
  . placebo
  pill_attach "command=false" "data_path=shunit2/fixtures"
  pill_record
  false > /dev/null ; rc1="$?"
  assertEquals "mocked false returns exit status that is not 1" "$rc1" "1"
  pill_detach

  . placebo
  pill_attach "command=false" "data_path=shunit2/fixtures"
  pill_playback
  false > /dev/null ; rc2="$?"
  assertEquals "false is not a function" "function" "$(type -t false)"
  assertEquals "mocked false returns exit status that is not 1" "$rc2" "1"
  pill_detach

  command rm -f shunit2/fixtures/false.sh
}

. shunit2
