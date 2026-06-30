# Forms, Credentials, and Interactions

Use this playbook for login, signup, checkout, validation, filters, modals, menus, accordions, toggles, and other mechanical interactions.

## Credentials

Credentials stay in `.env` or another configured file. Pass only:

- env file path;
- username/email variable name;
- password/API key variable name;
- target URL;
- expected post-action state.

The browser executor must not echo credential values.

## Interaction Prompt

Provide all field values and expected controls explicitly:

```text
Navigate to <url>.
Read credentials from <env-file> using <USER_VAR> and <PASS_VAR>.
Fill <field> with <value>.
Click <button>.
Report JSON: action, fields_filled, validation_messages, final_url, success, errors, page_state_after.
Do not include secret values.
```

## Validation Checks

For required fields and error states, capture:

- which fields are required;
- whether validation text is visible and screen-reader-addressable;
- disabled/enabled state of the primary action;
- focus behavior after submit;
- visual state after the interaction.

Load `visual-testing.md` when the requested check depends on colors, layout, or screenshots.
