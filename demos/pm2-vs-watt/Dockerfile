FROM node:20-alpine

WORKDIR /app

# Copy application files
COPY . ./

# Install dependencies
RUN npm install --omit=dev && npm cache clean --force

# Make entrypoint script executable
RUN chmod +x entrypoint.sh

# Expose port
EXPOSE 3000-3004

# Set environment variables
ENV HOSTNAME=0.0.0.0

# Use entrypoint script
CMD ["./entrypoint.sh"]
