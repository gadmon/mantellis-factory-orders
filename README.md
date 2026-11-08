# Mantellis Factory Orders

An ordering hub for the Mantelli's Direct stores and the factory. Stores order cases, each product has a par (the cases needed before the factory produces it), HQ sees every order and sets delivery costs, and a forecast is built from order history.

This site is plain files. It is hosted free on GitHub Pages. Orders and logins live in a Supabase database, which enforces who can see what.

Who sees what:
- A store sees only its own orders. The board shows totals ("7 of 10 cases, 2 stores waiting") with no store names.
- HQ sees everything, sets pars and delivery costs, and starts production.
- The database refuses orders from stores while orders are closed, and always uses current prices.

Files:
- `index.html` the whole app
- `config.js` the two connection values you fill in
- `schema.sql` the database, run once

## Set up (about 30 minutes, once)

Screen labels in Supabase and GitHub change now and then, so follow the idea if a label differs slightly.

### 1. Create the database
1. Sign up at supabase.com and choose New project. Name it, set a database password (save it somewhere safe) and pick the region closest to you (Cape Town if offered).
2. Open SQL Editor, New query. Paste the whole of `schema.sql` and press Run. It should finish without errors. This loads the tables, the privacy rules, the 123 products and the 19 stores.

### 2. Lock sign-ups
1. Authentication, Sign In / Providers (or Settings): switch OFF "Allow new users to sign up". Only people HQ creates can sign in.
2. Authentication, URL Configuration: set Site URL to your GitHub Pages address (step 4). This makes the "Forgot password" email link return to the site.

### 3. Create the first HQ login
1. Authentication, Users, Add user, Create new user. Enter the email and a password. Tick Auto Confirm User.
2. In SQL Editor run, with that email:
   `update public.profiles set role = 'hq' where email = 'hq@example.com';`

### 4. Publish the site on GitHub
1. In Supabase open Project Settings, API (or Data API). Copy the Project URL and the anon / public key.
2. Create a public GitHub repository and upload `index.html`, `config.js`, `schema.sql`, `README.md` and `.nojekyll`.
3. Open `config.js` in GitHub (pencil icon), paste the URL and anon key between the quotes, and commit.
4. Repository Settings, Pages: Source "Deploy from a branch", branch `main`, folder `/ (root)`. After a minute the site is at `https://YOUR-NAME.github.io/REPO-NAME/`.
5. Go back to step 2.2 and put that address in as the Site URL.

The anon key and the code are public. That is normal: nothing can be read without a login, and the database rules decide what each login can see. Never put the `service_role` key anywhere in the repository.

### 5. First run as HQ
1. Open the site and sign in with the HQ login.
2. Setup, Production pars: enter the real par for each product (the placeholder is 10 cases).
3. Setup, Rules: check lead time (10 business days), orders close 23 Nov 2026, reopen 5 Jan 2027, last delivery 20 Dec 2026, VAT, and the optional delivery rate per kg.

### 6. Add store logins
For each store:
1. Supabase, Authentication, Users, Add user (email, password, Auto Confirm User).
2. In the app: Setup, Logins. Change that person's Store to their store.
Several people at one store can have separate logins linked to the same store. They all see the store's orders. A login that is not linked to a store sees nothing.

To reset a forgotten password, the person uses "Forgot password" on the sign-in page, or HQ edits the user in Supabase.

## Day to day
- Stores: Production board, enter cases (or "+N to trigger" to reach par), or upload their usual order sheet on New order. Then send.
- HQ: All orders, By product. "Start production" moves every waiting case for that product. Then "Mark ready" and "Collected / delivered".
- Delivery cost: All orders, By order. Open a delivery order, enter pallet weight and cost, save. The store sees it on its order.
- Forecast: import past orders as CSV (date, store, code, cases) to start it. New orders add to the history automatically.

## Things to know
- Free Supabase projects pause after about a week without use and have no automatic backups. For live ordering, consider the paid plan, and use "Copy order lines as CSV" on All orders as a regular backup.
- Page data refreshes when you switch tabs and every 30 seconds.
- Uploading an order sheet reads the quantity column as cases and needs an internet connection.
- Tested against a local PostgreSQL copy of this schema and with a stand-in for the Supabase client. It has not been run against a live Supabase project, so do a trial with two or three stores before inviting everyone.

## Filled progress
When HQ marks an order line "In production", a **Save filled** box appears beside it (HQ view). HQ types how many cases have been filled so far; the franchisee sees a progress bar and "N of M cases filled" on the order and on each line. Ready/collected lines show as fully filled.
