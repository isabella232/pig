/**
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with this
 * work for additional information regarding copyright ownership. The ASF
 * licenses this file to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
package org.apache.pig.builtin;

import java.io.IOException;
import java.util.LinkedList;
import java.util.List;

import org.apache.hadoop.mapreduce.Job;
import org.apache.pig.StoreFuncMetadataWrapper;
import org.apache.pig.StoreMetadata;
import org.apache.pig.StoreResources;
import org.apache.pig.impl.logicalLayer.FrontendException;
import org.apache.pig.impl.util.JarManager;

/**
 * Wrapper class which will delegate calls to org.apache.parquet.pig.ParquetStorer
 */
public class ParquetStorer extends StoreFuncMetadataWrapper implements StoreResources {

    private static final String PARQUET_STORER_FQCN = "org.apache.parquet.pig.ParquetStorer";

    public ParquetStorer() throws FrontendException {
        Throwable exception = null;
        try {
            init((StoreMetadata) Class.forName(PARQUET_STORER_FQCN).newInstance());
        }
        // if compile time dependency not found at runtime
        catch (NoClassDefFoundError e) {
          exception = e;
        } catch (ClassNotFoundException e) {
          exception = e;
        } catch (InstantiationException e) {
          exception = e;
        } catch (IllegalAccessException e) {
          exception = e;
        }

        if(exception != null) {
            throw new FrontendException(String.format("Cannot instantiate class %s (%s)",
              getClass().getName(), PARQUET_STORER_FQCN), 2259, exception);
        }
    }
    
    private void init(StoreMetadata storeMetadata) {
        setStoreFunc(storeMetadata);
    }
    
    /**
     * {@inheritDoc}
     */
    @Override
    public void setStoreLocation(String location, Job job) throws IOException {
      try {
          JarManager.addDependencyJars(job, Class.forName("org.apache.parquet.Version"));
      } catch (ClassNotFoundException e) {
          throw new IOException("Runtime parquet dependency not found", e);
      }
      super.setStoreLocation(location, job);
    }

    @Override
    public List<String> getCacheFiles() {
        return null;
    }

    @Override
    public List<String> getShipFiles() {
        List<Class> classList = new LinkedList<>();
        try {
            classList.add(Class.forName(PARQUET_STORER_FQCN));
        } catch (ClassNotFoundException e) {
            throw new RuntimeException(String.format("Cannot find class %s (%s)",
                    getClass().getName(), PARQUET_STORER_FQCN), e);
        }
        return FuncUtils.getShipFiles(classList);
    }

}
