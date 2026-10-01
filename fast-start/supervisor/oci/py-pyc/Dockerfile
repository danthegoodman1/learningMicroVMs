# The official Python images ship no .pyc files, so every interpreter start
# recompiles the standard library. Precompiling once at conversion time fixes it.
FROM fast-start-oci-py
RUN python3 -m compileall -q -j0 /usr/local/lib/python3.12 /app
