# rrq

> Simple Redis Queue

[![Linux Build Status](https://travis-ci.org/richfitz/rrq.svg?branch=master)](https://travis-ci.org/richfitz/rrq)
Simple Redis queue in R.  This is like the bigger package `rrqueue`, but using `context` for most of the heavy lifting and aiming to be more like the lightweight parallelisation packages out there.

Once this works I'll rework `rrqueue` off of this codebase probably.

## Installation

```r
drat:::add("dide-tools")
install.packages("rrq")
```

## License

MIT + file LICENSE © [Rich FitzJohn](https://github.com/richfitz).
