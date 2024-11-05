# untested, from chatgpt

# Start with the Rust official image, using an Alpine variant for musl compatibility
FROM rust:alpine AS builder

# Install dependencies for static linking
RUN apk add --no-cache musl-dev

# Set up the working directory
WORKDIR /app

# Copy your Rust source files into the Docker image
COPY . .

# Build the Rust application with static linking
RUN cargo build --release --target x86_64-unknown-linux-musl

# Start a new, minimal image
FROM scratch AS rootfs

# Copy only the statically compiled binary to the new image
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/your_program /your_program

# Set the command to run your binary by default
ENTRYPOINT ["/your_program"]
