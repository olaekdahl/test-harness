# Build stage
FROM node:20 AS build
WORKDIR /app

# Accept the API URL as a build argument
ARG VITE_API_URL
# Set the environment variable for Vite during the build
ENV VITE_API_URL=$VITE_API_URL

COPY package*.json ./
RUN npm install
COPY . .

# Ensure the API URL is accessible during the build
RUN npm run build

# Runtime stage
FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]