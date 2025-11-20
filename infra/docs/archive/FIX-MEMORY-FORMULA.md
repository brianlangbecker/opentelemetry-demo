# Honeycomb Calculated Field: Memory Usage Percentage

**Purpose:** Create a properly formatted Honeycomb calculated field (derived column) to calculate memory usage as a percentage.

---

## Honeycomb Calculated Field Definition

### Field Configuration

**Column Name:** `memory_usage_percent`

**Description:** Memory usage as percentage (0-100%) calculated from working_set and available memory, or from limit if available.

**Type:** Number (Float)

---

## Formula Options

### Option 1: Using working_set + available (Recommended)

**Use this if:** You have both `k8s.pod.memory.working_set` and `k8s.pod.memory.available`

**Formula:**
```
IF(
  AND(
    $k8s.pod.memory.working_set EXISTS,
    $k8s.pod.memory.available EXISTS,
    ($k8s.pod.memory.working_set + $k8s.pod.memory.available) > 0
  ),
  ($k8s.pod.memory.working_set / ($k8s.pod.memory.working_set + $k8s.pod.memory.available)) * 100,
  null
)
```

**What it calculates:**
- Total memory = `working_set + available`
- Percentage = `(working_set / total) * 100`
- Returns `null` if fields are missing or total is zero

---

### Option 2: Using working_set + limit (Most Accurate)

**Use this if:** You have `k8s.pod.memory.working_set` and `k8s.pod.memory.limit`

**Formula:**
```
IF(
  AND(
    $k8s.pod.memory.working_set EXISTS,
    $k8s.pod.memory.limit EXISTS,
    $k8s.pod.memory.limit > 0
  ),
  ($k8s.pod.memory.working_set / $k8s.pod.memory.limit) * 100,
  null
)
```

**What it calculates:**
- Percentage = `(working_set / limit) * 100`
- This is the most accurate as it uses the actual memory limit
- Returns `null` if limit is missing or zero

---

### Option 3: Using utilization metric (Simplest)

**Use this if:** You have `k8s.pod.memory_limit_utilization` (already a percentage 0.0-1.0)

**Formula:**
```
IF(
  $k8s.pod.memory_limit_utilization EXISTS,
  $k8s.pod.memory_limit_utilization * 100,
  null
)
```

**What it calculates:**
- Converts utilization (0.0-1.0) to percentage (0-100%)
- Simplest formula if this metric exists

---

### Option 4: Robust Multi-Fallback (Best for Production)

**Use this if:** You want to try multiple methods in order

**Formula:**
```
COALESCE(
  IF(
    AND(
      $k8s.pod.memory.working_set EXISTS,
      $k8s.pod.memory.limit EXISTS,
      $k8s.pod.memory.limit > 0
    ),
    ($k8s.pod.memory.working_set / $k8s.pod.memory.limit) * 100,
    null
  ),
  IF(
    AND(
      $k8s.pod.memory.working_set EXISTS,
      $k8s.pod.memory.available EXISTS,
      ($k8s.pod.memory.working_set + $k8s.pod.memory.available) > 0
    ),
    ($k8s.pod.memory.working_set / ($k8s.pod.memory.working_set + $k8s.pod.memory.available)) * 100,
    null
  ),
  IF(
    $k8s.pod.memory_limit_utilization EXISTS,
    $k8s.pod.memory_limit_utilization * 100,
    null
  )
)
```

**What it does:**
1. **First tries:** `working_set / limit * 100` (most accurate)
2. **Then tries:** `working_set / (working_set + available) * 100` (fallback)
3. **Finally tries:** `memory_limit_utilization * 100` (simplest)
4. **Returns:** `null` if none are available

---

## Step-by-Step: Create in Honeycomb UI

1. **Navigate to:** Honeycomb UI → Your Dataset → **Columns** → **Create Column**

2. **Basic Settings:**
   - **Column Name:** `memory_usage_percent`
   - **Description:** `Memory usage percentage (0-100%) calculated from pod memory metrics`
   - **Type:** Number (Float)

3. **Formula:** Copy one of the formulas above (Option 2 or Option 4 recommended)

4. **Click:** **"Create"**

5. **Verify:** Run a test query to ensure it works

---

## Your Original Formula (Incorrect - For Reference)

```
IF( 
  AND( 
    EXISTS( $k8s.pod.memory.usage ), 
    EXISTS( $k8s.pod.memory.available ) 
  ), 
  MUL( 
    DIV( $k8s.pod.memory.usage, SUM( $k8s.pod.memory.usage, $k8s.pod.memory.available ) ), 
    100 
  ) 
)
```

**Issues:**
1. ❌ `EXISTS()` - Should be `EXISTS` (no parentheses)
2. ❌ `MUL()`, `DIV()`, `SUM()` - Should use operators `*`, `/`, `+`
3. ❌ `k8s.pod.memory.usage` - May not exist, use `k8s.pod.memory.working_set` instead

---

## Honeycomb Formula Syntax Reference

### Correct Syntax Patterns

| Operation | Correct Syntax | Example |
|-----------|----------------|---------|
| Field reference | `$field.name` | `$k8s.pod.memory.working_set` |
| Check if exists | `$field EXISTS` | `$k8s.pod.memory.working_set EXISTS` |
| Check if null | `$field != null` | `$k8s.pod.memory.working_set != null` |
| Addition | `a + b` | `$field1 + $field2` |
| Subtraction | `a - b` | `$field1 - $field2` |
| Multiplication | `a * b` | `$field1 * 100` |
| Division | `a / b` | `$field1 / $field2` |
| Conditional | `IF(condition, true_value, false_value)` | `IF($field > 0, $field, null)` |
| Logical AND | `AND(condition1, condition2)` | `AND($field1 EXISTS, $field2 EXISTS)` |
| Logical OR | `OR(condition1, condition2)` | `OR($field1 EXISTS, $field2 EXISTS)` |
| Coalesce | `COALESCE(value1, value2, ...)` | `COALESCE($field1, $field2, 0)` |

### Common Mistakes

| ❌ Incorrect | ✅ Correct |
|--------------|-----------|
| `EXISTS( $field )` | `$field EXISTS` |
| `MUL( a, b )` | `a * b` |
| `DIV( a, b )` | `a / b` |
| `SUM( a, b )` | `a + b` |
| `$field.name` (no $) | `$field.name` (with $) |

---

## Step-by-Step: Create the Derived Column

1. **Go to Honeycomb UI** → Your dataset → **Columns** → **Create Column**

2. **Column Name:** `memory_usage_percent`

3. **Formula:** Use Option 1 or Option 2 above

4. **Click "Create"**

---

## Verify the Formula Works

### Test Query

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE
  k8s.pod.memory.working_set,
  k8s.pod.memory.available,
  memory_usage_percent
LIMIT 20
```

**Expected:**
- `working_set` and `available` should have values
- `memory_usage_percent` should show percentage (0-100%)

---

## If Still Not Working

### Check What Fields Actually Exist

```
WHERE k8s.pod.name STARTS_WITH checkout
VISUALIZE COUNT
BREAKDOWN *
LIMIT 200
```

**Look for:**
- `k8s.pod.memory.working_set` ✅ (most common)
- `k8s.pod.memory.usage` ❓ (may not exist)
- `k8s.pod.memory.available` ✅ (should exist)

### Alternative: Use Only Fields That Exist

If `available` doesn't exist, use `limit` instead:

```
IF(
  AND(
    $k8s.pod.memory.working_set EXISTS,
    $k8s.pod.memory.limit EXISTS,
    $k8s.pod.memory.limit > 0
  ),
  ($k8s.pod.memory.working_set / $k8s.pod.memory.limit) * 100,
  null
)
```

Or use `memory_limit_utilization` if available:

```
IF(
  $k8s.pod.memory_limit_utilization EXISTS,
  $k8s.pod.memory_limit_utilization * 100,
  null
)
```

---

## Common Errors

### Error: "Field not found"
- **Fix:** Use `k8s.pod.memory.working_set` instead of `k8s.pod.memory.usage`

### Error: "Invalid function"
- **Fix:** Use operators (`+`, `-`, `*`, `/`) instead of functions (`SUM()`, `MUL()`, `DIV()`)

### Error: "EXISTS() is not a function"
- **Fix:** Use `$field EXISTS` instead of `EXISTS($field)`

### Error: "Division by zero"
- **Fix:** Add check: `($k8s.pod.memory.working_set + $k8s.pod.memory.available) > 0`

---

## Recommended Formula (Most Robust)

```
COALESCE(
  IF(
    AND(
      $k8s.pod.memory.working_set EXISTS,
      $k8s.pod.memory.limit EXISTS,
      $k8s.pod.memory.limit > 0
    ),
    ($k8s.pod.memory.working_set / $k8s.pod.memory.limit) * 100,
    null
  ),
  IF(
    AND(
      $k8s.pod.memory.working_set EXISTS,
      $k8s.pod.memory.available EXISTS,
      ($k8s.pod.memory.working_set + $k8s.pod.memory.available) > 0
    ),
    ($k8s.pod.memory.working_set / ($k8s.pod.memory.working_set + $k8s.pod.memory.available)) * 100,
    null
  ),
  IF(
    $k8s.pod.memory_limit_utilization EXISTS,
    $k8s.pod.memory_limit_utilization * 100,
    null
  )
)
```

**What this does:**
1. First tries: `working_set / limit * 100` (if limit exists)
2. Then tries: `working_set / (working_set + available) * 100` (if available exists)
3. Finally tries: `memory_limit_utilization * 100` (if utilization exists)
4. Returns `null` if none are available

---

**Last Updated:** December 2024  
**Status:** Formula fix guide

