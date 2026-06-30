# Permission Testing

Use this playbook for role-based access, tenant boundaries, login/logout, and restricted UI.

## Method

1. Main session defines the role matrix and expected permissions.
2. Browser executor logs out.
3. Browser executor logs in as the configured test role using env var names.
4. Browser executor navigates to allowed and restricted pages.
5. Browser executor inventories visible actions and reports status/errors.
6. Main session evaluates whether access and visibility match the matrix.

## Evidence

Capture:

- role tested;
- credential variable names, not values;
- target path;
- status code or rendered access denial;
- visible/hidden actions;
- leaks of restricted data.
