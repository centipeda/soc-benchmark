#!/bin/bash

# RUN-BENCHMARKS.sh
#
# Runs benchmarks from https://github.com/centipeda/zynq-benchmark.git on a machine.
# Follows the procedure specified in https://github.com/centipeda/zynq-benchmark/blob/master/RunningBenchmarks.md.
# Unfortunately, you'll have to put the results into SubmittingReuslts.md yourself!  # FIXME
# This assumes that you have root access on this machine.


### CONSTANTS

THIS_DIR="$(dirname $0)"
SRC_DIR="$THIS_DIR/benchmark_src"
BASE_RESULTS_DIR="$THIS_DIR/benchmark_results"
SCRIPTS_DIR="$THIS_DIR/benchmark_scripts"
INFORMATION_FILE="information.txt" # file to store extra info about benchmark run
DOWNLOAD_SOURCE="1"
MACHINE_NAME="speedyboi"  # "hostname" command not necessarily installed, that's done below
CHECK_PACKAGES="1"
ARCH=$(uname -m)  # get this machine's architecture
RUN_NETWORK="0"  # by default, don't run networking tests with iperf and ping
RUN_BENCHMARKS="1"  # if true, run basic benchmarking tests (Coremark, Dhrystone, Whetstone)
PROCESS_RESULTS="1"  # by default, perform statistical analysis on benchmarking results using python3

# Automatically detect number of threads
if [ $(command -v nproc) ] ; then
  THREADS=$(nproc)
else
  THREADS=2
fi

function usage {
  cat <<EOF
Usage: [sudo] $0

Runs benchmarks from https://github.com/centipeda/zynq-benchmark.git.
Follows the procedure specified in https://github.com/centipeda/zynq-benchmark/blob/master/RunningBenchmarks.md.
This script assumes that you have root access on the machine you run this on.

Arguments:
-h, --help                    Display this message.

-r, --just-raw-data           By default, this script performs basic statistical analysis on benchmark scores
                              (mean, std. deviation), installing Python 3 if it isn't already. This option
                              disables both of those.

-p, --process-results [results dir]

                              Only process results, don't run any benchmarks. (Basically, the opposite of the
                              -r flag.) Useful if you want to process benchmarking results on a different machine
                              than you ran the tests.

-c, --check-pkgs              Checks if the required commands are installed - git if downloading coremark
                              source, iperf3 if running networking tests, python3 if processing information.
                              Will remind the user to install numpy and matplotlib python modules if both
                              networking and processing flags are selected.

-d, --dry-run                 Don't run benchmarks, just check if requisite packages are installed.

-n, --network-test [ip addr]  Run iperf3 throughput test and ping latency test. Note the remote machine
                              must have the same version of iperf installed and be running in server mode
                              (iperf3 -s).

-j, --just-network [ip addr]  Run iperf3 throughput test and ping latency test and no other benchmarks.

--no-download                 Don't attempt to download the Coremark source code from the Coremark GitHub
                              repository (assumes the code is present.) Will cause the script to fail if the
                              Coremark source is not present in $SRC_DIR/coremark.
EOF
  exit $1
}

### SETUP

# Check if git, python3 (if processing), and iperf3 (if network tests) are installed.
# Aborts the script if not all appropriate packages are installed.
function check_pkgs {
  echo "Checking for prerequisite packages..."

  # Checks if a shell command with the given name exists.
  # Args: [the command: e.g., git, bash, python3]
  function isinstalled {
    if [ $(command -v $1) ]; then
      true
    else
      false
    fi
  }

  CHECK_SUCCESS=1  # Stays a one until something isn't installed, then turns zero,
                   # which causes the program to exit after check_pkgs

  if ! isinstalled hostname; then
    echo "Command 'hostname' not installed. Setting this machine's name to 'speedyboi'."
  else
    MACHINE_NAME="$(hostname)"
  fi

  if [ "$RUN_BENCHMARKS" != "0" ]; then
    if ! isinstalled gcc; then
      echo "To run benchmarks, please install some version of gcc first."
      CHECK_SUCCESS=0
    else
      echo "This benchmarking suite uses gcc to compile and run benchmarks."
      echo "Please ensure that you have your preferred version installed - feel free to ctrl-C now to check."
      echo
    fi
    if ! isinstalled make; then
      echo "To run benchmarks, please install some version of make first."
      CHECK_SUCCESS=0
    fi
  fi

  if [ "$DOWNLOAD_SOURCE" != "0" ]; then
    if ! isinstalled git; then
      echo "To download coremark source, please install git first."
      CHECK_SUCCESS=0
    fi
  fi

  if [ "$RUN_NETWORK" != "0" ]; then
    if ! isinstalled iperf3; then
      echo "To run network tests, please install iperf3 first."
      CHECK_SUCCESS=0
    fi
  fi

  if [ "$PROCESS_RESULTS" != "0" ]; then
    if ! isinstalled python3; then
      echo "To process results, please install python3 first."
      CHECK_SUCCESS=0
    fi
    if [ "$RUN_NETWORK" != "0" ]; then
      echo "To process network benchmarking results, matplotlib and numpy python packages must be installed."
      echo "This script cannot ascertain the status of installation of these packages."
      echo "Do you wish to exit the program and install these/check their status, or continue running?"
      select yn in Continue Halt; do
          case $yn in
              Continue ) make install; break;;
              Halt ) exit 1;;
              * ) echo "Please enter '1' or '2'."
          esac
      done
    fi
  fi

  if [ "$CHECK_SUCCESS" != "1" ]; then
    exit 1
  fi

}

### BENCHMARKING

# Sets up directory structure, downloads coremark source if specified
function setup {

  echo "Creating directory $RESULTS_DIR..."
  mkdir -p $RESULTS_DIR
  echo "Attempting to update Coremark source..."
  if [ $DOWNLOAD_SOURCE == "1" ] ; then
    COREMARK_SRC_FAIL_MSSG="If the source code is present in $SRC_DIR/coremark,
      run this script again with the --no-download flag to attempt to run Coremark anyway."
    git submodule update --init || echo $COREMARK_SRC_FAIL_MSSG
  fi
  echo "Completed setup."

}

# Record CPU and memory usage into the file ps.txt every $WAIT_TIME
# seconds until a "0" is written to benchmkark_active.txt.
# Args: a string identifying a ps process
function log_hw {

  echo "1" >> $RESULTS_DIR/benchmark_active.txt

  WAIT_TIME=2
  while [ $(tail -n 1 $RESULTS_DIR/benchmark_active.txt) == "1" ]
  do
    ps -C $1 -o %cpu,%mem >> $RESULTS_DIR/ps.txt  # Note that this assumes linux ps
    sleep $WAIT_TIME
  done

}

# Stops logging CPU and memory usage by reading a zero into the file
# benchmark_active.txt.
function stop_log_hw {
  echo "0" >> $RESULTS_DIR/benchmark_active.txt
}

# Runs coremark benchmarking tests on this machine.
# Stores results in RESULTS_DIR.
function run_coremark {
  echo "Running Coremark..."

  # if non-arm architecture, remove arm compiler flags from run file
  arm="-march=armv7-a -mcpu=cortex-a9 -mfpu=neon-fp16 -march=armv7-a"
  if [ $ARCH != arm* ]; then
    arm=""
  fi

  XCFLAGS="-O3 -DMULTITHREAD=${THREADS} -DUSE_PTHREAD -pthread -lrt ${arm}"

  # Run coremark
  log_hw "coremark.exe" "$RESULTS_DIR" &
  make -s -C $SRC_DIR/coremark clean
  for n in {1..10}
  do
    make -s -C $SRC_DIR/coremark XCFLAGS="$XCFLAGS"
    echo "Run #$n: $(tail -n 1 $SRC_DIR/coremark/run1.log)"
    tail -n 1 $SRC_DIR/coremark/run1.log >> $RESULTS_DIR/coremark.txt
  done

  # clean up
  echo "Cleaning Coremark source..."
  make -C $SRC_DIR/coremark clean

  stop_log_hw
}

# Run dhrystone benchmarking tests on this machine.
# Stores results in RESULTS_DIR.
function run_dhrystone {
  echo "Running Dhrystone..."

  echo "Cleaning Dhrystone source..."
  make -C $SRC_DIR/dhrystone clean

  # Set Makefile variables.
  TIME_FUNC="-DTIME" # Might need to be "-DTIME or -DTIMES" instead, depending on the system.
  if [ $ARCH == "arm" ]; then
    GCCOPTIM="-O -O3 -Ofast --mcpu=cortex-a9 -mfpu=vfpv3-fp16"
  else
    GCCOPTIM="-O -O3 -Ofast"
  fi

  echo "Compiling Dhrystone..."
  make -C $SRC_DIR/dhrystone TIME_FUNC="$TIME_FUNC" GCCOPTIM="$GCCOPTIM" all

  log_hw "gcc_dry2reg" "$RESULTS_DIR" &

  RUNS=10
  ITERS=100000000
  echo "Running Dhrystone, no registers..."
  for i in $( seq 1 $RUNS )
  do
    printf "run #$i: "
    echo $ITERS | $SRC_DIR/dhrystone/gcc_dry2 | tail -n 2 | head -n 1 | tee -a $RESULTS_DIR/dhrystone.txt
  done

  echo "Running Dhrystone with registers..."
  for i in $( seq 1 $RUNS )
  do
    printf "run #$i: "
    echo $ITERS | $SRC_DIR/dhrystone/gcc_dry2reg | tail -n 2 | head -n 1 | tee -a $RESULTS_DIR/dhrystone.txt
  done

  echo "Cleaning Dhrystone source..."
  make -C $SRC_DIR/dhrystone clean

  stop_log_hw
}

# Run whetstone benchmarking tests on this machine.
# Stores results in RESULTS_DIR.
function run_whetstone {
  echo "Running Whetstone..."

  # Set compiler flags
  if [ $ARCH == "arm" ]; then
    CFLAGS="-O3 -Ofast --mcpu=cortex-a9 -mfpu=vfpv3-fp16 -DNDEBUG -lm"
  else
    CFLAGS="-O3 -Ofast -lm"
  fi

  echo "Compiling Whetstone..."
  make -C $SRC_DIR/whetstone CFLAGS="$CFLAGS" whetstone

  log_hw "whetstone" "$RESULTS_DIR" &
  LOOPS=1000000
  for n in {1..10}
  do
    printf "Run #$n: "
    $SRC_DIR/whetstone/whetstone $LOOPS | tail -n 1 | tee -a $RESULTS_DIR/whetstone.txt
  done

  echo "Cleaning Whetstone source directory..."
  make -C $SRC_DIR/whetstone clean

  stop_log_hw
}

# Runs network tests using iperf with some remote ip.
function run_iperf {
  echo "Testing network with iperf with remote IP address $REMOTE_IP..."

  mkdir $RESULTS_DIR/iperf

  # UDP datagram size in bytes
  frame_size=1500
  step_size=2000

  while [ $frame_size -lt 65508 ]
  do
    echo "[" >> $RESULTS_DIR/iperf/iperf_result_${frame_size}.json
    i=0
    while [ $i -lt 10 ]
    do
      # -b sets maximum bitrate in b/s (default is 1Mb/s); -Z uses "zero copy" to save CPU; man iperf3 for more
      iperf3 -c $REMOTE_IP -u -b 1000000000 -l $frame_size -J -Z >> $RESULTS_DIR/iperf/iperf_result_${frame_size}.json
      echo "," >> $RESULTS_DIR/iperf/iperf_result_${frame_size}.json
      i=$((i+1))
    done
    echo "]" >> $RESULTS_DIR/iperf/iperf_result_${frame_size}.json
    frame_size=$((frame_size+step_size))
  done

}

# Runs latency tests using ping with some remote ip.
function run_ping {
  echo "Testing latency using ping with remote IP address $REMOTE_IP..."

  mkdir $RESULTS_DIR/ping

  # So far, these are all ping defaults spelled out for configurability's sake
  PACKET_SIZE=56  # bytes
  NUM_PINGS=10  # number of times to ping server

  # No processing - ping is nice enough to do that for us
  ping -c $NUM_PINGS -s $PACKET_SIZE $REMOTE_IP >> $RESULTS_DIR/ping/ping_results.txt

}

# Processes results stored in text file in RESULTS_DIR.
function process_results {
  echo "Processing raw results files using python3..."

  if [ "$RUN_BENCHMARKS" != "0" ]; then
    python3 $SCRIPTS_DIR/process_results.py --coremark-file $RESULTS_DIR/coremark.txt \
                                            --dhrystone-file $RESULTS_DIR/dhrystone.txt \
                                            --whetstone-file $RESULTS_DIR/whetstone.txt \
                                            --output-file $RESULTS_DIR/summary.txt
  fi

  if [ -d $RESULTS_DIR/iperf ]; then
    python3 $SCRIPTS_DIR/process_iperf.py $RESULTS_DIR/iperf
    # no need to process ping
  fi

}

function create_info_file {
  tee $RESULTS_DIR/$INFORMATION_FILE <<EOF
name:
compiler:
cpu:
date: $(date +"%B %e, %Y")
notes:
EOF
}

function main {

  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help)
        usage 0
        ;;
      -p|--process-results)
        RUN_BENCHMARKS=0
        RUN_NETWORK=0
        PROCESS_RESULTS=1
        ;;
      -r|--just-raw-data)
        PROCESS_RESULTS=0
        ;;
      -d|--dry-run)
        RUN_BENCHMARKS=0
        RUN_NETWORK=0
        PROCESS_RESULTS=0
        ;;
      -c|--check-pkgs)
        CHECK_PACKAGES=1
        ;;
      --no-download)
        DOWNLOAD_SOURCE=0
        ;;
      -n|--network-test)
        shift
        RUN_NETWORK=1
        REMOTE_IP="$1"
        ;;
      -j|--just-network)
        shift
        RUN_NETWORK=1
        RUN_BENCHMARKS=0
        REMOTE_IP="$1"
        ;;
      *)
        RESULTS_DIR="$1"
        ;;
    esac
    shift
  done

  if [ $CHECK_PACKAGES == "1" ] ; then
    check_pkgs
  fi

  echo "RESULTS DIR: $RESULTS_DIR"
  if [ -z "$RESULTS_DIR" ]; then
    RESULTS_DIR=$(date +"$BASE_RESULTS_DIR/${MACHINE_NAME}_results_%Y%m%d_%H%M%S")
  fi
  echo "RESULTS DIR: $RESULTS_DIR"

  echo $0, $(date +"%Y-%m-%d %H:%M:%S"), selected parameters:
  echo "THIS_DIRECTORY:           $THIS_DIR"
  echo "SRC_DIRECTORY:            $SRC_DIR"
  echo "SCRIPTS_DIRECTORY:        $SCRIPTS_DIR"
  echo "RESULTS_DIRECTORY:        $RESULTS_DIR"
  echo "CHECK_PACKAGES:           $CHECK_PACKAGES"
  echo "RUN_NETWORK_TESTS:        $RUN_NETWORK"
  echo "RUN_BENCHMARK_TESTS:      $RUN_BENCHMARKS"
  echo "PROCESS_RESULTS:          $PROCESS_RESULTS"
  echo "DOWNLOAD_COREMARK_SOURCE: $DOWNLOAD_SOURCE"
  echo "THREADS:                  $THREADS"

  setup $RESULTS_DIR

  if [ "$RUN_BENCHMARKS" != "0" ]; then
    run_coremark
    run_dhrystone
    run_whetstone
  fi

  if [ "$RUN_NETWORK" != "0" ]; then
    if [ ! -z "$REMOTE_IP" ]; then
      run_iperf
      run_ping
    else
      echo "REMOTE_IP option for -n not defined."
    fi
  fi

  # Process results.txt files
  if [ "$PROCESS_RESULTS" != "0" ]; then
    process_results
  fi

  echo "Creating information file... please fill out the following fields in the file $RESULTS_DIR/$INFORMATION_FILE to provide context for these benchmarks." 
  create_info_file

  echo
  echo "Benchmarking process complete! The run results have been stored in $RESULTS_DIR."

  echo "Exiting program."

}

main $@

