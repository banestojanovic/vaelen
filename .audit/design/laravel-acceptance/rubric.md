# Laravel connection acceptance design rubric

Score each candidate from 1 to 5 on:

1. Exercises the actual `val` connection apply output without substituting a synthetic dotenv file.
2. Boots an official Laravel app with its real `phpdotenv` behavior in both uncached and cached configuration modes.
3. Keeps Composer and framework setup reproducible and bounds network/build work to a disposable test root.
4. Prevents database passwords from appearing in process arguments, ordinary output, or committed fixtures.
5. Fits the existing private-Core MySQL journey and cleanup ownership without duplicating the provisioning flow.
