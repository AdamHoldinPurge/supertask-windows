"""Claude prompt templates for SuperTask™ autonomous loop."""
import time
from datetime import datetime


# ---------------------------------------------------------------------------
# 1. INIT_PROMPT — used when creating the initial PLAN.md
# ---------------------------------------------------------------------------
INIT_PROMPT = """\
You are initializing an autonomous loop.{variant_label} Mission: "{mission}"
{creative_addon}{brief_addon}

CRITICAL RULE: You MUST write PLAN.md to disk BEFORE doing anything else. Do NOT research, fetch websites, or explore extensively first. Write the plan file IMMEDIATELY based on what you already know, then refine it if budget allows.

STEP 1 — WRITE PLAN.md NOW with this structure:

# Autonomous Plan

## Mission
{mission}

## Creative Direction
{preset}

## Context
[Quick scan of the current directory only. Read any CLAUDE.md, README.md, package.json if they exist. Write 5-15 bullet points. Do NOT fetch external URLs — the loop iterations will handle research.]

## Active Tasks (Priority Order)
[Generate 5-8 concrete, specific tasks based on the mission. Each completable in ~30 min. Task 1 should be research/analysis if needed. Do NOT do the research yourself — just plan it as a task.]
1. [ ] First task
2. [ ] Second task
...

## Completed
(none yet)

## Discoveries
(none yet)

## Meta
- Cycles: 0
- Iterations: 0
- Tasks completed: 0
- Variant: {variant_num} of {num_variants} ({preset})
- Last replanned: {timestamp}
- Last updated: {timestamp}
- Mission started: {timestamp}

STEP 2 — Verify PLAN.md exists on disk (read it back).
STEP 3 — Create autoloop-logs/ directory if it doesn't exist.

IMPORTANT: The autonomous loop will handle ALL the actual work. Your ONLY job is to create a solid starting plan. Do NOT try to execute any tasks. Do NOT fetch external websites. Do NOT install dependencies. Just write the plan and stop.\
"""


# ---------------------------------------------------------------------------
# 2. RALPH_PROMPT — base executor prompt
# ---------------------------------------------------------------------------
RALPH_PROMPT = """\
You are the EXECUTOR inside an autonomous Ralph loop.

READ PLAN.md NOW. Then:

1. Look at "Active Tasks (Priority Order)" — find the FIRST unchecked [ ] task
2. EXECUTE it. Write code, run commands, deploy, research, analyze. Do the actual work.
3. When done, update PLAN.md:
   - Mark the task [x] with a brief result note
   - Update Context if you discovered important facts
   - Add a Discoveries bullet point for what you learned
   - Increment "Iterations" and "Tasks completed" in Meta
   - Update "Last updated" timestamp
4. Append a one-line summary to autoloop-logs/history.log:
   [timestamp] Ralph iteration: [task] — [result]

IMPORTANT:
- Do NOT generate new tasks. That is the Replan phase's job.
- Do NOT rewrite the plan. Just mark your task done and update context.
- Focus entirely on EXECUTING the single top task well.
- If the task is too big, do as much as you can and note what remains.
- Be honest about failures — note them clearly in the task result.
- If there are NO unchecked tasks remaining, write "ALL_TASKS_COMPLETE" to autoloop-logs/ralph_signal.txt and stop.\
"""


# ---------------------------------------------------------------------------
# 3. REPLAN_PROMPT — base planner prompt
# ---------------------------------------------------------------------------
REPLAN_PROMPT = """\
You are the STRATEGIC PLANNER inside an autonomous loop.

Ralph just finished executing all the tasks in PLAN.md. Your job is to review what happened and generate a BRAND NEW plan.

READ PLAN.md NOW — especially the Completed section and Discoveries.

Then REWRITE PLAN.md with:

## Mission
[Keep the original mission — never change this]

## Creative Direction
[Keep the original creative direction — never change this]

## Context
[Keep existing context. Add any new facts from the completed work. Remove anything outdated.]

## Active Tasks (Priority Order)
[Generate 5-10 NEW, specific, actionable tasks. These should be:]
- Based on what was accomplished and discovered in the previous cycle
- The logical next steps toward the Mission
- A mix of: building/implementing, testing/validating, researching/exploring, monitoring/maintaining
- Specific enough to execute in ~30 minutes each ("implement X in file Y" not "improve Z")
- Prioritized: most impactful first
- Consider: what failed and needs fixing? What succeeded and can be built on? What new opportunities emerged?

## Completed
[Move the PREVIOUS completed items to an archive section or keep only the last 20. Add a cycle summary line:]
- Cycle N complete: [1-line summary of what the whole cycle accomplished]

## Discoveries
[Keep all discoveries — this is institutional memory. Add a cycle-level insight.]

## Meta
- Cycles: [increment by 1]
- Iterations: [keep running total from Ralph]
- Tasks completed: [keep running total]
- Last replanned: [current timestamp]
- Last updated: [current timestamp]

RULES:
- Active Tasks must have 5-10 items. Never fewer.
- Tasks must be NOVEL — do not repeat tasks that were already completed.
- Think strategically: what moves the Mission forward fastest?
- Consider diminishing returns — if one area is well-optimized, shift focus elsewhere.
- Include at least 1 research/exploration task to discover new opportunities.
- Write the plan, then write a replan summary to autoloop-logs/replan_N.md

After writing PLAN.md, also delete autoloop-logs/ralph_signal.txt if it exists.\
"""


# ---------------------------------------------------------------------------
# 4. POLISH_PROMPT — base finish prompt
# ---------------------------------------------------------------------------
POLISH_PROMPT = """\
You are finishing up an autonomous loop. The user has requested a GRACEFUL STOP.

READ PLAN.md NOW.

Your job is to POLISH and FINALIZE everything:

1. Review all recent changes — read autoloop-logs/history.log to see what was done.
2. Fix any loose ends: incomplete implementations, TODO comments, missing error handling.
3. Clean up: remove debug logs, temp files, commented-out code.
4. If this is a website (check the project files and PLAN.md Context for localhost URL):
   - Make sure the dev server is still running on localhost. If not, restart it.
   - Run a FULL Playwright verification of the entire site against localhost — every page, every button, every form, responsive checks at 375/768/1440px, console errors, asset loading.
   - Fix any broken links, missing images, layout issues.
   - Ensure all pages load cleanly with no console errors.
   - Note the localhost URL and how to start the dev server in the final summary so the user can pick up where you left off.
5. Update PLAN.md:
   - Mark any in-progress tasks with their current state
   - Add a final section: "## Session Summary" with what was accomplished across all cycles
   - Note anything the user should review or that needs manual attention
   - If website: include the localhost URL and dev server start command
6. Write a final summary to autoloop-logs/final_summary.md:
   - What was built/changed
   - What works
   - What needs attention
   - Recommended next steps
   - If website: localhost URL, dev server command, and how to view the site

This is the LAST iteration. Make everything clean, polished, and ready for the user to pick up.\
"""


# ---------------------------------------------------------------------------
# 5. WEBSITE_BUILDER_ADDON — injected when website-builder mode is active
# ---------------------------------------------------------------------------
WEBSITE_BUILDER_ADDON = """\
WEBSITE BUILDER MODE — LOCAL DEVELOPMENT:
- Start a local dev server (e.g. python -m http.server, npx serve, npm run dev) on the FIRST iteration
- Keep the dev server running throughout all iterations
- After every significant change, verify in the browser using Playwright against localhost
- ALL development happens locally — no deployment until the user says so

VERIFICATION CHECKLIST (run after every major change):
1. All pages load without console errors
2. All navigation links work (no 404s)
3. All images/assets load correctly
4. Responsive layout works at 375px, 768px, 1440px widths
5. All interactive elements (buttons, forms, modals) function correctly
6. Text is readable — no overlapping, no overflow, no truncation
7. Colors and fonts match the creative direction
8. Performance is acceptable — no massive layout shifts or slow loads\
"""


# ---------------------------------------------------------------------------
# 6. Builder functions
# ---------------------------------------------------------------------------

def build_creative_injection(preset_name: str, preset_description: str) -> str:
    """Return the creative direction injection text.

    If preset is 'Faithful' or empty, returns empty string.
    Otherwise returns the multi-line creative direction block.
    """
    if not preset_name or preset_name == "Faithful":
        return ""
    return (
        f"\n== CREATIVE DIRECTION ==\n"
        f"Preset: {preset_name}\n"
        f"{preset_description}\n"
        f"Apply this creative direction to ALL visual and copy decisions.\n"
        f"== END CREATIVE DIRECTION ==\n"
    )


def build_brief_addon(brief_data: dict | None) -> str:
    """Build the website brief addon from a brief data dict.

    Expected keys: brand_dna, brand_logos, brand_reference_images,
    brand_urls, brand_notes, inspiration_urls, inspiration_images,
    inspiration_notes, master_prompt.

    Returns formatted prompt text or empty string if brief_data is
    None / empty.
    """
    if not brief_data:
        return ""

    sections: list[str] = []
    sections.append("\n== WEBSITE BRIEF ==")

    if brief_data.get("brand_dna"):
        sections.append(f"BRAND DNA: {brief_data['brand_dna']}")

    if brief_data.get("brand_logos"):
        logos = brief_data["brand_logos"]
        if isinstance(logos, list):
            logos = ", ".join(logos)
        sections.append(f"BRAND LOGOS (read these files): {logos}")

    if brief_data.get("brand_reference_images"):
        refs = brief_data["brand_reference_images"]
        if isinstance(refs, list):
            refs = ", ".join(refs)
        sections.append(f"BRAND REFERENCE IMAGES (read these files): {refs}")

    if brief_data.get("brand_urls"):
        urls = brief_data["brand_urls"]
        if isinstance(urls, list):
            urls = ", ".join(urls)
        sections.append(f"BRAND URLS (fetch and analyze these): {urls}")

    if brief_data.get("brand_notes"):
        sections.append(f"BRAND NOTES: {brief_data['brand_notes']}")

    if brief_data.get("inspiration_urls"):
        urls = brief_data["inspiration_urls"]
        if isinstance(urls, list):
            urls = ", ".join(urls)
        sections.append(f"INSPIRATION URLS (fetch and analyze these): {urls}")

    if brief_data.get("inspiration_images"):
        imgs = brief_data["inspiration_images"]
        if isinstance(imgs, list):
            imgs = ", ".join(imgs)
        sections.append(f"INSPIRATION IMAGES (read these files): {imgs}")

    if brief_data.get("inspiration_notes"):
        sections.append(f"INSPIRATION NOTES: {brief_data['inspiration_notes']}")

    if brief_data.get("master_prompt"):
        sections.append(f"MASTER PROMPT: {brief_data['master_prompt']}")

    sections.append("== END WEBSITE BRIEF ==")

    return "\n".join(sections) + "\n"


def build_time_context(start_time: float, time_limit: int) -> str:
    """Build a time-awareness string for injection into prompts.

    Args:
        start_time: Epoch float when the session started.
        time_limit: Total session time in seconds. 0 means unlimited.

    Returns:
        A single-line string such as:
        "TIME: You have approximately 2h 15m remaining in this session. "
    """
    if time_limit <= 0:
        return "TIME: You have unlimited time in this session. "

    elapsed = time.time() - start_time
    remaining = max(0, time_limit - elapsed)

    if remaining <= 0:
        return "TIME: Time is up. Wrap up immediately and polish your work. "

    if remaining < 300:
        return "TIME: Only 5 minutes remaining. Focus on completing and polishing your current task. "

    hours = int(remaining // 3600)
    minutes = int((remaining % 3600) // 60)

    if hours > 0:
        return f"TIME: You have approximately {hours}h {minutes:02d}m remaining in this session. "
    else:
        return f"TIME: You have approximately {minutes}m remaining in this session. "


def build_init_prompt(
    mission: str,
    preset: str,
    variant_num: int,
    num_variants: int,
    creative_addon: str,
    brief_addon: str,
) -> str:
    """Fill in the INIT_PROMPT template and return the complete prompt."""
    if num_variants > 1:
        variant_label = f" [Variant {variant_num}/{num_variants} — {preset}]"
    else:
        variant_label = ""

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    return INIT_PROMPT.format(
        variant_label=variant_label,
        mission=mission,
        creative_addon=creative_addon,
        brief_addon=brief_addon,
        preset=preset,
        num_variants=num_variants,
        variant_num=variant_num,
        timestamp=timestamp,
    )


def build_ralph_prompt(
    time_ctx: str,
    variant_ctx: str,
    creative_text: str,
    website_addon: str,
    brief_addon: str,
) -> str:
    """Build the complete Ralph executor prompt from all pieces."""
    parts: list[str] = []

    if time_ctx:
        parts.append(time_ctx)
    if variant_ctx:
        parts.append(variant_ctx)
    if creative_text:
        parts.append(creative_text)
    if website_addon:
        parts.append(website_addon)
    if brief_addon:
        parts.append(brief_addon)

    parts.append(RALPH_PROMPT)
    return "\n".join(parts)


def build_replan_prompt(
    time_ctx: str,
    variant_ctx: str,
    creative_text: str,
    brief_addon: str,
) -> str:
    """Build the complete Replan prompt from all pieces."""
    parts: list[str] = []

    if time_ctx:
        parts.append(time_ctx)
    if variant_ctx:
        parts.append(variant_ctx)
    if creative_text:
        parts.append(creative_text)
    if brief_addon:
        parts.append(brief_addon)

    parts.append(REPLAN_PROMPT)
    return "\n".join(parts)


def build_polish_prompt(
    variant_label: str,
    creative_text: str,
    brief_addon: str,
) -> str:
    """Build the complete Polish prompt from all pieces."""
    parts: list[str] = []

    if variant_label:
        parts.append(variant_label)
    if creative_text:
        parts.append(creative_text)
    if brief_addon:
        parts.append(brief_addon)

    parts.append(POLISH_PROMPT)
    return "\n".join(parts)
