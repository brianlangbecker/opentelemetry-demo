# Exploring Available Memory Metrics in Honeycomb

**Purpose:** Discover what memory metrics are available and determine the correct formula for calculating memory usage percentage.

---

## Step 1: Find All Memory-Related Fields

### Query 1: List All Memory Fields

```
WHERE k8s.pod.name EXISTS
VISUALIZE COUNT
BREAKDOWN *
LIMIT 100
```

**Then filter the results** to find fields containing "memory":
- Look for fields like `k8s.pod.memory.*`
- Note which ones have values vs. null

### Query 2: Check Specific Memory Fields

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  MAX(k8s.pod.memory.usage) AS "Memory Usage",
  MAX(k8s.pod.memory.available) AS "Memory Available",
  MAX(k8s.pod.memory.limit) AS "Memory Limit",
  MAX(k8s.pod.memory.working_set) AS "Memory Working Set",
  MAX(k8s.pod.memory_limit_utilization) AS "Memory Utilization"
GROUP BY k8s.pod.name
LIMIT 20
```

**What to look for:**
- Which fields have values (not null)?
- What are the typical values?
- Do `usage + available` equal a total?

---

## Step 2: Understand the Relationship Between Fields

### Query 3: Check if usage + available = total

```
WHERE k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.available EXISTS
VISUALIZE
  MAX(k8s.pod.memory.usage) AS "Usage",
  MAX(k8s.pod.memory.available) AS "Available",
  MAX(k8s.pod.memory.usage) + MAX(k8s.pod.memory.available) AS "Total (usage + available)",
  MAX(k8s.pod.memory.limit) AS "Limit"
GROUP BY k8s.pod.name
LIMIT 20
```

**What to check:**
- Does `usage + available` equal `limit` (if limit exists)?
- Or is `usage + available` a different total (like node memory)?

### Query 4: Compare utilization metric to calculated percentage

```
WHERE k8s.pod.memory_limit_utilization EXISTS
  AND k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.limit EXISTS
VISUALIZE
  MAX(k8s.pod.memory_limit_utilization) * 100 AS "Utilization Metric (%)",
  (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 AS "Calculated (%)",
  MAX(k8s.pod.memory_limit_utilization) * 100 - (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 AS "Difference"
GROUP BY k8s.pod.name
LIMIT 20
```

**What to check:**
- Do the values match?
- If they match, `utilization` is likely `usage / limit`

---

## Step 3: Test Different Calculation Methods

### Query 5: Test Method 1 (usage / limit)

```
WHERE k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.limit EXISTS
  AND k8s.pod.memory.limit > 0
VISUALIZE
  MAX(k8s.pod.memory.usage) AS "Usage (bytes)",
  MAX(k8s.pod.memory.limit) AS "Limit (bytes)",
  (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100 AS "Usage %"
GROUP BY k8s.pod.name
ORDER BY "Usage %" DESC
LIMIT 20
```

**Check:** Do the percentages look reasonable (0-100%)?

### Query 6: Test Method 2 (usage / (usage + available))

```
WHERE k8s.pod.memory.usage EXISTS
  AND k8s.pod.memory.available EXISTS
VISUALIZE
  MAX(k8s.pod.memory.usage) AS "Usage (bytes)",
  MAX(k8s.pod.memory.available) AS "Available (bytes)",
  MAX(k8s.pod.memory.usage) + MAX(k8s.pod.memory.available) AS "Total (bytes)",
  (MAX(k8s.pod.memory.usage) / (MAX(k8s.pod.memory.usage) + MAX(k8s.pod.memory.available))) * 100 AS "Usage %"
GROUP BY k8s.pod.name
ORDER BY "Usage %" DESC
LIMIT 20
```

**Check:** 
- Does `usage + available` make sense as total?
- Do percentages look reasonable?

### Query 7: Test Method 3 (utilization metric)

```
WHERE k8s.pod.memory_limit_utilization EXISTS
VISUALIZE
  MAX(k8s.pod.memory_limit_utilization) AS "Utilization (0-1)",
  MAX(k8s.pod.memory_limit_utilization) * 100 AS "Utilization (%)"
GROUP BY k8s.pod.name
ORDER BY "Utilization (%)" DESC
LIMIT 20
```

**Check:** Are values between 0-1? Multiply by 100 for percentage.

---

## Step 4: Determine Which Fields Are Available

### Query 8: Count how many pods have each field

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  COUNT(WHERE k8s.pod.memory.usage EXISTS) AS "Has usage",
  COUNT(WHERE k8s.pod.memory.available EXISTS) AS "Has available",
  COUNT(WHERE k8s.pod.memory.limit EXISTS) AS "Has limit",
  COUNT(WHERE k8s.pod.memory_limit_utilization EXISTS) AS "Has utilization"
GROUP BY time(1h)
```

**What to check:**
- Which fields are most commonly available?
- Use the most available field for your formula

---

## Step 5: Sample Data Inspection

### Query 9: Get sample rows with all memory fields

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  k8s.pod.name,
  k8s.pod.memory.usage,
  k8s.pod.memory.available,
  k8s.pod.memory.limit,
  k8s.pod.memory.working_set,
  k8s.pod.memory_limit_utilization
ORDER BY timestamp DESC
LIMIT 50
```

**What to do:**
- Look at actual values
- See which fields are populated
- Understand the data structure

---

## Step 6: Verify Calculation Logic

### Query 10: Cross-check all methods

```
WHERE k8s.pod.name EXISTS
VISUALIZE
  k8s.pod.name,
  MAX(k8s.pod.memory.usage) AS "usage",
  MAX(k8s.pod.memory.available) AS "available",
  MAX(k8s.pod.memory.limit) AS "limit",
  MAX(k8s.pod.memory_limit_utilization) AS "utilization",
  IF(
    MAX(k8s.pod.memory.limit) > 0,
    (MAX(k8s.pod.memory.usage) / MAX(k8s.pod.memory.limit)) * 100,
    null
  ) AS "calc_from_limit",
  IF(
    MAX(k8s.pod.memory.available) > 0,
    (MAX(k8s.pod.memory.usage) / (MAX(k8s.pod.memory.usage) + MAX(k8s.pod.memory.available))) * 100,
    null
  ) AS "calc_from_available",
  MAX(k8s.pod.memory_limit_utilization) * 100 AS "from_utilization"
GROUP BY k8s.pod.name
LIMIT 20
```

**What to check:**
- Which calculation method gives reasonable results?
- Do any methods match the `utilization` metric?
- Which method works for the most pods?

---

## Step 7: Create the Derived Column

Based on your findings, create the derived column using the method that:
1. Works for the most pods (most fields available)
2. Gives reasonable percentage values (0-100%)
3. Matches the `utilization` metric (if it exists)

### Example Based on Common Findings:

**If `limit` is available:**
```
IF(
  AND($k8s.pod.memory.usage EXISTS, $k8s.pod.memory.limit EXISTS, $k8s.pod.memory.limit > 0),
  ($k8s.pod.memory.usage / $k8s.pod.memory.limit) * 100,
  null
)
```

**If only `available` is available:**
```
IF(
  AND(
    $k8s.pod.memory.usage EXISTS,
    $k8s.pod.memory.available EXISTS,
    ($k8s.pod.memory.usage + $k8s.pod.memory.available) > 0
  ),
  ($k8s.pod.memory.usage / ($k8s.pod.memory.usage + $k8s.pod.memory.available)) * 100,
  null
)
```

**If `utilization` exists:**
```
IF(
  $k8s.pod.memory_limit_utilization EXISTS,
  $k8s.pod.memory_limit_utilization * 100,
  null
)
```

---

## Quick Reference: Field Discovery

Run this query to see all fields containing "memory":

```
WHERE k8s.pod.name EXISTS
VISUALIZE COUNT
BREAKDOWN *
```

**Then manually filter** the breakdown results to find:
- `k8s.pod.memory.*` fields
- Any other memory-related fields

---

**Next Steps:**
1. Run Query 1-2 to see what fields exist
2. Run Query 3-4 to understand relationships
3. Run Query 5-7 to test calculation methods
4. Run Query 8 to see field availability
5. Run Query 9-10 to verify logic
6. Create derived column based on findings

---

**Last Updated:** December 2024  
**Status:** Exploration guide

