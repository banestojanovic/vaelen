# Projects

## Sub-features

- Browse known projects and their settings.
- Inspect available project actions.
- Link a project directly from the status popover when the confirmed project list is empty.

## How to get to it (user POV)

Open Vaelen Settings and choose **Projects** in the Workspace section.

## Driving it with CUA

Launch the `partial` Debug fixture, choose **Projects**, and capture the page. Record whether the fixture presents an empty or populated state; require the Projects heading and the fixture marker. Do not open folders, editors, routes, or external applications.

## Gotchas

Fixture projects are not a live project registry. This navigation check does not prove linking, route status, editor launching, or Core refresh behavior. If the fixture does not satisfy a journey precondition, report that rather than seeding real user projects.

The status popover only shows its **Link Project…** empty-state action after Core is running and reports no projects. Verify it on a confirmed-empty live state; the Settings fixture does not cover this popover journey. Do not select or link a real folder during visual verification.
