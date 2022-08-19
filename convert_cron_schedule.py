import croniter
import datetime
import sys

# Variables
now = datetime.datetime.now()
sched = sys.argv[1]
argument = sys.argv[2]    
cron = croniter.croniter(sched, now)

# Dates
nextdate = cron.get_next(datetime.datetime)
nextdatets_int = int(round(nextdate.timestamp() * 1000))
prevdate = cron.get_prev(datetime.datetime)
prevdatets_int = int(round(prevdate.timestamp() * 1000))

schedulediff = nextdatets_int - prevdatets_int

# Get next cron run
if argument == "next_run":
    print(nextdatets_int)

# Get difference between cron runs
elif argument == "difftimestamp":
    print(schedulediff)

else:
    print("Unknown arguments.")
