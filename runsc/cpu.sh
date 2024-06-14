#!/bin/bash

PID=$(cat pid.txt)

# Read the /proc/4731/stat file
STAT=$(cat /proc/$PID/stat)

# Extract the relevant fields (14, 15, 22)
UTIME=$(echo $STAT | awk '{print $14}')
STIME=$(echo $STAT | awk '{print $15}')
STARTTIME=$(echo $STAT | awk '{print $22}')

# Read the /proc/uptime file
UPTIME=$(cat /proc/uptime | awk '{print $1}')

# Read the system clock ticks per second (sysconf(_SC_CLK_TCK))
CLK_TCK=$(getconf CLK_TCK)

# Calculate the total time spent for the process
TOTAL_TIME=$((UTIME + STIME))

# Calculate the process start time
START_TIME=$((STARTTIME / CLK_TCK))

# Calculate the elapsed time since the process started
ELAPSED_TIME=$(echo "$UPTIME - $START_TIME" | bc)

# Calculate the CPU usage as a percentage
CPU_USAGE=$(echo "($TOTAL_TIME / $CLK_TCK) / $ELAPSED_TIME * 100" | bc -l)

echo "CPU usage of process $PID: $CPU_USAGE%"
