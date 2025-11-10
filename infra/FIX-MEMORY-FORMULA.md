# Fix Memory Usage Percentage Formula

**Problem:** Derived column formula not working in Honeycomb.

---

## Your Original Formula (Incorrect Syntax)

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
1. ❌ `EXISTS()` - Should be `EXISTS` (no parentheses) or check for null
2. ❌ `MUL()`, `DIV()`, `SUM()` - Should use operators `*`, `/`, `+`
3. ❌ `k8s.pod.memory.usage` - May not exist, use `k8s.pod.memory.working_set` instead

---

## Corrected Formula

### Option 1: Using EXISTS (No Parentheses)

```
IF(
  AND(
    $k8s.pod.memory.working_set EXISTS,
    $k8s.pod.memory.available EXISTS
  ),
  ($k8s.pod.memory.working_set / ($k8s.pod.memory.working_set + $k8s.pod.memory.available)) * 100,
  null
)
```

### Option 2: Using Null Check (More Explicit)

```
IF(
  AND(
    $k8s.pod.memory.working_set != null,
    $k8s.pod.memory.available != null,
    ($k8s.pod.memory.working_set + $k8s.pod.memory.available) > 0
  ),
  ($k8s.pod.memory.working_set / ($k8s.pod.memory.working_set + $k8s.pod.memory.available)) * 100,
  null
)
```

### Option 3: If You Have `usage` Field (Less Common)

```
IF(
  AND(
    $k8s.pod.memory.usage EXISTS,
    $k8s.pod.memory.available EXISTS
  ),
  ($k8s.pod.memory.usage / ($k8s.pod.memory.usage + $k8s.pod.memory.available)) * 100,
  null
)
```

---

## Key Syntax Differences

| Your Syntax | Correct Syntax |
|-------------|----------------|
| `EXISTS( $field )` | `$field EXISTS` |
| `MUL( a, b )` | `a * b` |
| `DIV( a, b )` | `a / b` |
| `SUM( a, b )` | `a + b` |

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

