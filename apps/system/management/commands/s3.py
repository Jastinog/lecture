import boto3
import tempfile
import os
from django.core.management.base import BaseCommand
from django.core.files.storage import default_storage
from django.core.files.base import ContentFile
from django.conf import settings


class Command(BaseCommand):
    help = 'Test S3 storage configuration and connectivity'

    def handle(self, *args, **options):
        self.stdout.write("=== Testing S3 Storage Configuration ===\n")
        
        # 1. Check settings
        self.stdout.write("1. Settings check:")
        self.stdout.write(f"   DEFAULT_FILE_STORAGE: {settings.DEFAULT_FILE_STORAGE}")
        self.stdout.write(f"   USE_S3_MEDIA: {getattr(settings, 'USE_S3_MEDIA', 'NOT_SET')}")
        self.stdout.write(f"   AWS_STORAGE_BUCKET_NAME: {getattr(settings, 'AWS_STORAGE_BUCKET_NAME', 'NOT_SET')}")
        self.stdout.write(f"   AWS_S3_REGION_NAME: {getattr(settings, 'AWS_S3_REGION_NAME', 'NOT_SET')}")
        
        # 2. Check storage instance
        self.stdout.write("\n2. Storage instance:")
        self.stdout.write(f"   default_storage type: {type(default_storage)}")
        self.stdout.write(f"   default_storage._wrapped type: {type(default_storage._wrapped)}")
        
        # Force initialization
        storage_instance = default_storage._wrapped
        self.stdout.write(f"   Storage class: {storage_instance.__class__}")
        self.stdout.write(f"   Has bucket_name: {hasattr(storage_instance, 'bucket_name')}")
        
        if hasattr(storage_instance, 'bucket_name'):
            self.stdout.write(f"   Bucket name: {storage_instance.bucket_name}")
        
        # 3. Test AWS credentials
        self.stdout.write("\n3. AWS connectivity test:")
        try:
            s3_client = boto3.client(
                's3',
                aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
                aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
                region_name=settings.AWS_S3_REGION_NAME
            )
            
            # List buckets
            response = s3_client.list_buckets()
            buckets = [bucket['Name'] for bucket in response['Buckets']]
            self.stdout.write(f"   Available buckets: {buckets}")
            
            # Check if our bucket exists
            bucket_name = settings.AWS_STORAGE_BUCKET_NAME
            if bucket_name in buckets:
                self.stdout.write(f"   ✓ Target bucket '{bucket_name}' found")
                
                # Test bucket access
                s3_client.head_bucket(Bucket=bucket_name)
                self.stdout.write(f"   ✓ Bucket '{bucket_name}' is accessible")
                
            else:
                self.stdout.write(f"   ✗ Target bucket '{bucket_name}' not found")
                
        except Exception as e:
            self.stdout.write(f"   ✗ AWS connection failed: {e}")
            return
        
        # 4. Test file upload through Django storage
        self.stdout.write("\n4. Django storage test:")
        try:
            # Create test content
            test_content = "This is a test file for S3 storage"
            test_file = ContentFile(test_content.encode('utf-8'))
            
            # Save through Django storage
            file_name = "test/storage_test.txt"
            saved_name = default_storage.save(file_name, test_file)
            
            self.stdout.write(f"   ✓ File saved as: {saved_name}")
            self.stdout.write(f"   ✓ File URL: {default_storage.url(saved_name)}")
            
            # Test file exists
            if default_storage.exists(saved_name):
                self.stdout.write(f"   ✓ File exists in storage")
                
                # Read back content
                with default_storage.open(saved_name, 'r') as f:
                    content = f.read()
                    if content.strip() == test_content:
                        self.stdout.write(f"   ✓ File content matches")
                    else:
                        self.stdout.write(f"   ✗ Content mismatch: {content}")
            else:
                self.stdout.write(f"   ✗ File not found in storage")
            
            # Clean up test file
            default_storage.delete(saved_name)
            self.stdout.write(f"   ✓ Test file cleaned up")
            
        except Exception as e:
            self.stdout.write(f"   ✗ Django storage test failed: {e}")
            import traceback
            self.stdout.write(f"   Traceback: {traceback.format_exc()}")
        
        # 5. Direct S3 upload test
        self.stdout.write("\n5. Direct S3 upload test:")
        try:
            test_key = "test/direct_s3_test.txt"
            test_content = "Direct S3 upload test"
            
            s3_client.put_object(
                Bucket=settings.AWS_STORAGE_BUCKET_NAME,
                Key=test_key,
                Body=test_content,
                ContentType='text/plain'
            )
            self.stdout.write(f"   ✓ Direct S3 upload successful")
            
            # Clean up
            s3_client.delete_object(
                Bucket=settings.AWS_STORAGE_BUCKET_NAME,
                Key=test_key
            )
            self.stdout.write(f"   ✓ Direct S3 test file cleaned up")
            
        except Exception as e:
            self.stdout.write(f"   ✗ Direct S3 upload failed: {e}")
        
        self.stdout.write("\n=== Test Complete ===")
