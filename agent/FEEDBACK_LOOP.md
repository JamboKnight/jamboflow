# JamboFlow Diagnostic — Feedback Loop & Log Analysis

Every conversation with the diagnostic is logged to the D1 database (`turns` table). This data is the foundation for continuous improvement. You should review these logs regularly to detect patterns, failures, and methodology refinement opportunities.

## What's being logged

**Turns table schema:**
```
- convo_id: Conversation ID (UUIDv4)
- country: Visitor's country (from CF-Connecting-IP header)
- kind: "exchange" (normal turn), "rate_limited" (quota exceeded), or "system_error"
- user_msg: The visitor's input (up to 2000 chars)
- assistant_msg: The agent's full response
- msg_count: Which turn this was (1-30)
- diagnosis: 1 if the response includes "What you came in with" (diagnosis delivered), 0 otherwise
- created_at: Timestamp

Every exchange is captured. Rate limits and errors are also logged for visibility.
```

## Analysis workflow

### 1. Diagnoses delivered (monthly)
Query conversations where `diagnosis = 1`. These are "successful" first-pass diagnoses.
```sql
SELECT COUNT(*) as total_diagnoses, COUNT(DISTINCT convo_id) as unique_conversations
FROM turns WHERE diagnosis = 1 AND created_at > date('now', '-30 days');
```

**What to look for:**
- Trend: Are diagnoses increasing or declining? Why?
- Depth: Read through a sample of diagnoses (maybe 10 random ones). Do they reveal real patterns or are they generic? Does the methodology shine through?
- Accuracy indicators: Do the diagnoses match the visitor's actual problem space? (You may need to follow up with visitors who booked calls.)

### 2. Conversations that stalled (weekly)
Conversations where `msg_count < 8 AND diagnosis = 0`. The agent should wrap up around 10-12 visitor turns.
```sql
SELECT convo_id, msg_count, country, user_msg, assistant_msg
FROM turns WHERE diagnosis = 0 AND msg_count < 8
ORDER BY created_at DESC LIMIT 20;
```

**What to look for:**
- Did the visitor go off-topic? (Check if you used the defensive redirects. Did they work?)
- Did the visitor provide insufficient information? (Was the opening question clear enough?)
- Did the agent get stuck or loop? (Read the full conversation thread—is the agent asking productive follow-ups, or repeating itself?)

### 3. Attack surface (ongoing)
Any message that contains keywords like "ignore," "system prompt," "instructions," "how do you work," "what are you," "forget."
```sql
SELECT convo_id, msg_count, user_msg, assistant_msg
FROM turns WHERE user_msg LIKE '%ignore%' OR user_msg LIKE '%system prompt%'
   OR user_msg LIKE '%instructions%' OR user_msg LIKE '%how do you work%'
ORDER BY created_at DESC;
```

**What to look for:**
- Are attack attempts increasing? (Suggests the diagnostic is getting more traffic or is a known target.)
- Did the agent handle them correctly? (Read the response—did it leak anything? Did it redirect properly?)
- Do you need to update the defensive posture training if new patterns emerge?

### 4. Geographic patterns (monthly)
Where are visitors coming from? Are some regions more engaged?
```sql
SELECT country, COUNT(*) as turns, COUNT(DISTINCT convo_id) as conversations,
       SUM(diagnosis) as diagnoses_delivered
FROM turns WHERE kind = 'exchange'
GROUP BY country ORDER BY turns DESC;
```

**What to look for:**
- Are certain regions more likely to complete diagnoses?
- Are there regions where the agent consistently stalls or fails?
- Does this inform marketing or positioning decisions?

### 5. Rate limiting (weekly)
Are legitimate visitors being cut off?
```sql
SELECT country, COUNT(*) as limited_attempts
FROM turns WHERE kind = 'rate_limited'
GROUP BY country ORDER BY limited_attempts DESC;
```

**What to look for:**
- If `IP_DAILY_LIMIT` (10) or `GLOBAL_DAILY_LIMIT` (200) is being hit frequently, you may have a surge in traffic (good) or coordinated bot activity (bad).
- If a single country is causing most rate-limit hits, consider a regional limit override.
- If legitimate high-volume testing is needed, adjust limits via environment variables before the test.

## Improvement actions

### If diagnoses are generic or miss patterns:
1. Review a sample of full conversations where diagnosis was delivered.
2. Compare the diagnosis to the visitor's actual issue (if they later booked a call—follow up).
3. Update the system prompt with a new diagnostic lens or more specific examples.
4. Re-test with a few sample conversations to verify the change sharpens the diagnosis.

### If visitors go off-topic or stall:
1. Review the opening question. Is it clear? (The interface pre-greets the visitor, so they know what the tool does.)
2. Read through a few stalled conversations. Where did the agent lose the thread?
3. Update the prompt's guidance on staying focused and recognizing off-topic drift.

### If attack patterns emerge:
1. Add the pattern to the "Defensive posture" section if it's novel.
2. Include an example of the attack and the correct response.
3. Re-deploy the updated prompt.

### If certain regions dominate:
1. Analyze whether traffic from those regions converts to bookings at a different rate.
2. Consider localized positioning or messaging for high-performing regions.
3. Investigate low-performing regions—is the agent less effective there, or is positioning/discovery the issue?

## Cadence

- **Weekly:** Check for stalled conversations and rate-limit hits. Scan for new attack patterns.
- **Monthly:** Review diagnoses delivered, geographic patterns, and overall quality trends. Plan any prompt updates.
- **Quarterly:** Deep-dive analysis—compare methodology across cohorts, identify systematic gaps, update the diagnostic brain if warranted.

## Notes

- Never delete logs. They are the institutional memory of the diagnostic's performance.
- If you make a change to the system prompt, make a note in this file or your project notes (CLAUDE.md) so you can correlate changes to performance shifts.
- The diagnostic is a learning system. Each conversation teaches you something about your target visitor's problems and where the methodology can sharpen.
