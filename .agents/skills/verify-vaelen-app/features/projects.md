# Projects

## Sub-features

- Browse known projects and their settings.
- Inspect available project actions.

## How to get to it (user POV)

Open Vaelen Settings and choose **Projects** in the Workspace section.

## Driving it with CUA

Launch the `partial` Debug fixture, choose **Projects**, and capture the page. Record whether the fixture presents an empty or populated state; require the Projects heading and the fixture marker. Do not open folders, editors, routes, or external applications.

## Gotchas

Fixture projects are not a live project registry. This navigation check does not prove linking, route status, editor launching, or Core refresh behavior. If the fixture does not satisfy a journey precondition, report that rather than seeding real user projects.
