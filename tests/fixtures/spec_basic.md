# My Feature Spec

## Goals

- [ ] G1: System supports user authentication
- [x] G2: Users can reset their password

## Requirements

- [ ] R1: User can log in with email and password
- [ ] R2: Session expires after 30 minutes of inactivity
- [x] R3: Passwords must be hashed with bcrypt

## Non-goals

- [ ] N1: Social login is out of scope for this version

## Open Questions

- [ ] Q1: Should session expiry reset on each request?
- [ ] Q2: What is the password complexity requirement?

## Edge Cases

- [ ] E1: User enters wrong password five times in a row

## Acceptance

- [ ] A1: Login flow passes all automated tests
- [ ] A2: Password reset email is sent within 5 seconds

## User Flow

- [ ] F1: User opens login page and submits credentials
