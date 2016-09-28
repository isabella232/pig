/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.pig.hive;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Timestamp;

import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.ql.io.orc.OrcFile;
import org.apache.hadoop.hive.ql.io.orc.OrcFile.Version;
import org.apache.hadoop.hive.ql.io.sarg.PredicateLeaf;
import org.apache.hadoop.hive.ql.io.sarg.SearchArgument;
import org.apache.hadoop.hive.ql.udf.generic.Collector;
import org.apache.hadoop.hive.ql.udf.generic.GenericUDF;
import org.apache.hadoop.hive.serde2.AbstractSerDe;
import org.apache.hadoop.hive.serde2.objectinspector.PrimitiveObjectInspector;
import org.apache.hadoop.hive.shims.HadoopShimsSecure;
import org.apache.hadoop.hive.shims.ShimLoader;
import org.joda.time.DateTime;

import com.esotericsoftware.kryo.Serializer;
import com.esotericsoftware.kryo.io.Input;

public class HiveShims {
    public static String normalizeOrcVersionName(String version) {
        return Version.byName(version).getName();
    }

    public static void addLessThanOpToBuilder(SearchArgument.Builder builder,
            String columnName, PredicateLeaf.Type columnType, Object value) {
        builder.lessThan(columnName, value);
    }

    public static void addLessThanEqualsOpToBuilder(SearchArgument.Builder builder,
            String columnName, PredicateLeaf.Type columnType, Object value) {
        builder.lessThanEquals(columnName, value);
    }

    public static void addEqualsOpToBuilder(SearchArgument.Builder builder,
            String columnName, PredicateLeaf.Type columnType, Object value) {
        builder.equals(columnName, value);
    }

    public static void addBetweenOpToBuilder(SearchArgument.Builder builder,
            String columnName, PredicateLeaf.Type columnType, Object low, Object high) {
        builder.between(columnName, low, high);
    }

    public static void addIsNullOpToBuilder(SearchArgument.Builder builder,
            String columnName, PredicateLeaf.Type columnType) {
        builder.isNull(columnName);
    }

    public static Class[] getOrcDependentClasses(Class hadoopVersionShimsClass) {
        return new Class[] {OrcFile.class, HiveConf.class, AbstractSerDe.class,
                org.apache.hadoop.hive.shims.HadoopShims.class, HadoopShimsSecure.class, hadoopVersionShimsClass,
                Input.class};
    }

    public static Class[] getHiveUDFDependentClasses(Class hadoopVersionShimsClass) {
        return new Class[] {GenericUDF.class,
                PrimitiveObjectInspector.class, HiveConf.class, Serializer.class, ShimLoader.class, 
                hadoopVersionShimsClass, HadoopShimsSecure.class, Collector.class};
    }

    public static Object getSearchArgObjValue(Object value) {
        if (value instanceof BigInteger) {
            return new BigDecimal((BigInteger)value);
        } else if (value instanceof DateTime) {
            return new Timestamp(((DateTime)value).getMillis());
        } else {
            return value;
        }
    }
}
