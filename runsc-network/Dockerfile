FROM docker.io/denoland/deno:2.1.5

WORKDIR /app

# Cache the dependencies
COPY counter.ts .

# Grant necessary permissions
RUN deno cache counter.ts

# The port that we're exposing
EXPOSE 8080

# Run the application
CMD ["deno", "run", "--allow-net", "counter.ts"]
